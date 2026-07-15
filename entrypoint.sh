#!/usr/bin/env bash
# One-time build, then serve. On first boot (no READY marker on the volume) this
# downloads the US extract, filters it down to the routable road network (so the
# osrm-extract memory peak fits under the 24 GB container limit — the full US
# needs more), runs the OSRM MLD pipeline into /data, then starts osrm-routed. On
# every later boot it finds READY and just serves (~1 min, no rebuild). So you can
# stop the service between load builds to save money and start it a minute before.
set -euo pipefail

DATA=/data
PBF_URL="${PBF_URL:-https://download.geofabrik.de/north-america/us-latest.osm.pbf}"
NAME="${OSRM_NAME:-us-latest}"
PBF="$DATA/$NAME.osm.pbf"          # full download
ROADS="$DATA/$NAME.roads.osm.pbf"  # road-network-only, what we actually extract
OSRM="$DATA/$NAME.roads.osrm"      # osrm files produced from ROADS
PORT="${PORT:-5000}"
THREADS="${OSRM_THREADS:-6}"

mkdir -p "$DATA"
cd "$DATA"

if [ ! -f "$DATA/READY" ]; then
  echo ">> One-time build starting."

  # 1. Download the full US extract (skip if we already produced the filtered roads).
  # Download to .part and rename only on success, so a killed download can never
  # leave a truncated file that the [ ! -f "$PBF" ] guard would mistake for a
  # finished one. -C - resumes an interrupted .part instead of restarting.
  if [ ! -f "$ROADS" ] && [ ! -f "$PBF" ]; then
    echo ">> Downloading US extract from $PBF_URL (~13 GB)"
    curl -fL -C - --retry 3 -o "$PBF.part" "$PBF_URL" \
      || curl -fkL -C - --retry 3 -o "$PBF.part" "$PBF_URL"
    mv "$PBF.part" "$PBF"
  fi

  # 2. Filter to highways + turn-restrictions (keeps their nodes automatically). This
  #    drops the ~90% of OSM data that isn't roads, so osrm-extract fits in 24 GB.
  #    osmconvert/osmfilter are self-contained static binaries (no apt needed).
  if [ ! -f "$ROADS" ]; then
    rm -f "$DATA/full.o5m" "$DATA/roads.o5m"  # drop partials from any earlier crash
    echo ">> Fetching osmconvert + osmfilter"
    curl -fL -o /usr/local/bin/osmconvert http://m.m.i24.cc/osmconvert64
    curl -fL -o /usr/local/bin/osmfilter  http://m.m.i24.cc/osmfilter64
    chmod +x /usr/local/bin/osmconvert /usr/local/bin/osmfilter

    # Each step deletes its input as soon as the output is complete. The whole
    # chain is disk-bound (~25 GB for full.o5m alone), so we never hold two big
    # intermediates at once. Losing the pbf is fine: a failure re-downloads it.
    echo ">> Converting pbf -> o5m"
    osmconvert "$PBF" -o="$DATA/full.o5m"
    rm -f "$PBF"
    df -h "$DATA" | tail -1

    # --hash-memory must be large enough to mark every referenced node ID or
    # osmfilter silently drops nodes and the road graph comes out full of holes.
    # US node IDs run into the billions; the 320 MB default is far too small.
    echo ">> Filtering road network"
    osmfilter "$DATA/full.o5m" --hash-memory=3000 \
      --keep="highway= or ( type=restriction )" --out-o5m -o="$DATA/roads.o5m"
    rm -f "$DATA/full.o5m"
    df -h "$DATA" | tail -1

    echo ">> Converting filtered set -> pbf"
    osmconvert "$DATA/roads.o5m" -o="$ROADS"
    rm -f "$DATA/roads.o5m"
    df -h "$DATA" | tail -1
    ls -lh "$ROADS"
  fi

  echo ">> osrm-extract (car profile, ${THREADS} threads)"
  osrm-extract -t "$THREADS" -p /opt/car.lua "$ROADS"
  echo ">> osrm-partition"
  osrm-partition -t "$THREADS" "$OSRM"
  echo ">> osrm-customize"
  osrm-customize -t "$THREADS" "$OSRM"
  touch "$DATA/READY"
  echo ">> Build complete."
fi

echo ">> Serving OSRM (MLD) on 0.0.0.0:$PORT"
exec osrm-routed --algorithm mld --ip 0.0.0.0 --port "$PORT" --max-table-size 10000 "$OSRM"
