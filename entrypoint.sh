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

mkdir -p "$DATA"
cd "$DATA"

if [ ! -f "$DATA/READY" ]; then
  echo ">> No processed graph yet. One-time build starting (expect 30-90 min)."
  if [ ! -f "$PBF" ]; then
    echo ">> Downloading US extract from $PBF_URL (~13 GB)"
    curl -fL --retry 3 -o "$PBF" "$PBF_URL"
  fi
  echo ">> osrm-extract (car profile)"
  osrm-extract -p /opt/car.lua "$PBF"
  echo ">> osrm-partition"
  osrm-partition "$OSRM"
  echo ">> osrm-customize"
  osrm-customize "$OSRM"
  touch "$DATA/READY"
  rm -f "$PBF"            # reclaim ~13 GB; the .osrm.* files are all we need to serve
  echo ">> Build complete."
fi

echo ">> Serving OSRM (MLD) on 0.0.0.0:$PORT"
exec osrm-routed --algorithm mld --ip 0.0.0.0 --port "$PORT" --max-table-size 10000 "$OSRM"
