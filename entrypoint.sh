#!/usr/bin/env bash
# One-time build, then serve. On first boot (no READY marker on the volume) this
# downloads the US extract and runs the OSRM MLD pipeline into /data, then starts
# osrm-routed. On every later boot it finds READY and just serves — a restart takes
# ~1 minute, no re-download, no re-preprocess. So you can stop the service between
# load builds to save money and start it a minute before you build.
set -euo pipefail

DATA=/data
PBF_URL="${PBF_URL:-https://download.geofabrik.de/north-america/us-latest.osm.pbf}"
NAME="${OSRM_NAME:-us-latest}"
PBF="$DATA/$NAME.osm.pbf"
OSRM="$DATA/$NAME.osrm"
PORT="${PORT:-5000}"
# Cap preprocessing threads to keep the memory peak under the container limit. The
# full-US osrm-extract with all cores (32) spikes past 24 GB and gets OOM-killed;
# fewer threads means smaller parallel buffers. Slower, but it fits. Tunable.
THREADS="${OSRM_THREADS:-4}"

mkdir -p "$DATA"
cd "$DATA"

if [ ! -f "$DATA/READY" ]; then
  echo ">> No processed graph yet. One-time build starting (expect 30-90 min)."
  if [ ! -f "$PBF" ]; then
    echo ">> Downloading US extract from $PBF_URL (~13 GB)"
    # Fall back to a no-cert-verify retry in case the old base image's CA bundle
    # doesn't trust the download host (public map data, so this is acceptable).
    curl -fL --retry 3 -o "$PBF" "$PBF_URL" || curl -fkL --retry 3 -o "$PBF" "$PBF_URL"
  fi
  echo ">> osrm-extract (car profile, ${THREADS} threads)"
  osrm-extract -t "$THREADS" -p /opt/car.lua "$PBF"
  echo ">> osrm-partition"
  osrm-partition -t "$THREADS" "$OSRM"
  echo ">> osrm-customize"
  osrm-customize -t "$THREADS" "$OSRM"
  touch "$DATA/READY"
  rm -f "$PBF"            # reclaim ~13 GB; the .osrm.* files are all we need to serve
  echo ">> Build complete."
fi

echo ">> Serving OSRM (MLD) on 0.0.0.0:$PORT"
exec osrm-routed --algorithm mld --ip 0.0.0.0 --port "$PORT" --max-table-size 10000 "$OSRM"
