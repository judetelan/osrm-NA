#!/usr/bin/env bash
# One-time build, then serve. On first boot (no READY marker on the volume) this
# downloads a Geofabrik extract, runs the OSRM MLD pipeline into /data, then
# starts osrm-routed. On every later boot it finds READY and just serves (~1 min,
# no rebuild), so the service can be stopped between load builds to save money and
# started a minute before.
#
# SIZE LIMITS, measured 2026-07-16 (see README):
#   osrm-extract on the full US does NOT fit in 24 GB. It needs ~60-105 GB and no
#   flag changes that. Regions of roughly Texas size build here fine. For the full
#   US, run the build on a big box and copy the .osrm.* files onto the volume;
#   this script skips straight to serving when it finds them plus READY.
set -euo pipefail

DATA=/data
PBF_URL="${PBF_URL:-https://download.geofabrik.de/north-america/us-latest.osm.pbf}"
NAME="${OSRM_NAME:-us-latest}"
PORT="${PORT:-5000}"
THREADS="${OSRM_THREADS:-6}"

# Road pre-filtering is OFF by default. It cuts the pbf a lot (US: 11 GB -> 3.8 GB)
# but only ~20-35% off the extract memory peak, which is not enough to bring the US
# under 24 GB, and it can drop turn-restriction relations whose members get filtered
# out. Only worth enabling to save disk on a box that already has the RAM.
FILTER="${OSRM_FILTER_ROADS:-}"

PBF="$DATA/$NAME.osm.pbf"
if [ -n "$FILTER" ]; then
  SRC="$DATA/$NAME.roads.osm.pbf"   # filtered road network, what we extract
else
  SRC="$PBF"                        # extract the download as-is
fi
OSRM="${SRC%.osm.pbf}.osrm"

mkdir -p "$DATA"
cd "$DATA"

if [ ! -f "$DATA/READY" ]; then
  echo ">> One-time build starting. Region: $NAME"

  # Download to .part and rename only on success, so a killed download can never
  # leave a truncated file that the [ ! -f "$PBF" ] guard would mistake for a
  # finished one. -C - resumes an interrupted .part instead of restarting.
  if [ ! -f "$SRC" ] && [ ! -f "$PBF" ]; then
    echo ">> Downloading $PBF_URL"
    curl -fL -C - --retry 3 -o "$PBF.part" "$PBF_URL" \
      || curl -fkL -C - --retry 3 -o "$PBF.part" "$PBF_URL"
    mv "$PBF.part" "$PBF"
  fi

  # osmconvert is used for the node count below even when filtering is off, so it
  # is always fetched. Both are self-contained static binaries (no apt needed).
  echo ">> Fetching osmconvert + osmfilter"
  curl -fL -o /usr/local/bin/osmconvert http://m.m.i24.cc/osmconvert64
  curl -fL -o /usr/local/bin/osmfilter  http://m.m.i24.cc/osmfilter64
  chmod +x /usr/local/bin/osmconvert /usr/local/bin/osmfilter

  if [ -n "$FILTER" ] && [ ! -f "$SRC" ]; then
    rm -f "$DATA/full.o5m" "$DATA/roads.o5m"  # drop partials from any earlier crash

    # Each step deletes its input as soon as the output is complete. The o5m of the
    # US alone is ~25 GB, so holding two intermediates at once overflows the volume.
    # Losing the pbf is fine: a failure re-downloads it.
    echo ">> Converting pbf -> o5m"
    osmconvert "$PBF" -o="$DATA/full.o5m"
    rm -f "$PBF"
    df -h "$DATA" | tail -1

    # --hash-memory must be large enough to mark every referenced node id or
    # osmfilter silently drops nodes and the road graph comes out full of holes.
    # US node ids run into the billions; the 320 MB default is far too small.
    echo ">> Filtering road network"
    osmfilter "$DATA/full.o5m" --hash-memory=3000 \
      --keep="highway= or ( type=restriction )" --out-o5m -o="$DATA/roads.o5m"
    rm -f "$DATA/full.o5m"
    df -h "$DATA" | tail -1

    echo ">> Converting filtered set -> pbf"
    osmconvert "$DATA/roads.o5m" -o="$SRC"
    rm -f "$DATA/roads.o5m"
    df -h "$DATA" | tail -1
  fi

  ls -lh "$SRC"

  # osrm-extract's peak RAM tracks node/way count, not file size, so this is the
  # number that decides whether a region fits. Cheap to compute (streams).
  echo ">> Counting nodes/ways in $SRC"
  osmconvert "$SRC" --out-statistics | grep -E "^(nodes|ways|relations|timestamp)" || true

  # Set OSRM_COUNT_ONLY=1 to stop here. Extract OOMs on regions too big for the
  # container and Railway then burns ~4 min of CPU per retry, five times over,
  # which is pure waste when all you wanted was the node count.
  if [ -n "${OSRM_COUNT_ONLY:-}" ]; then
    echo ">> OSRM_COUNT_ONLY set; stopping before extract."
    exit 0
  fi

  # -t is passed for partition/customize, where it genuinely bounds memory. It does
  # NOT bound extract: extractor.cpp hardcodes the pipeline's live-token budget to
  # hardware_concurrency() * 1.5 and ignores the flag. Do not expect it to help there.
  echo ">> osrm-extract (car profile, ${THREADS} threads)"
  osrm-extract -t "$THREADS" -p /opt/car.lua "$SRC"
  echo ">> osrm-partition"
  osrm-partition -t "$THREADS" "$OSRM"
  echo ">> osrm-customize"
  osrm-customize -t "$THREADS" "$OSRM"
  touch "$DATA/READY"
  echo ">> Build complete."
  df -h "$DATA" | tail -1
  du -sh "$DATA"/*.osrm* 2>/dev/null | tail -1 || true
fi

# --mmap maps the .osrm.* files read-only off the volume instead of loading them
# into anonymous memory. For the full US this is not an optimisation, it is the
# only way it fits: the graph is ~47 GB and osrm-routed without mmap resides at
# ~24 GB, right on the container ceiling. mmap'd pages are clean and file-backed,
# so the kernel reclaims them under pressure rather than OOM-killing us.
# This only holds while the graph is on a real disk. On tmpfs the pages are
# unreclaimable and the OOM comes back.
MMAP=""
if [ "${OSRM_MMAP:-1}" != "0" ]; then
  MMAP="--mmap"
  echo ">> Serving with --mmap (graph paged from the volume)"
fi

echo ">> Serving OSRM (MLD) on 0.0.0.0:$PORT from $OSRM"
exec osrm-routed --algorithm mld $MMAP --ip 0.0.0.0 --port "$PORT" \
  --max-table-size 10000 "$OSRM"
