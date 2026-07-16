#!/usr/bin/env bash
# Run ON THE DIGITALOCEAN DROPLET (256 GB memory-optimized, Ubuntu 24.04).
# Builds a full-US OSRM graph, then exits. Roughly 2-3 hours.
#
# This does NOT fit on Railway (24 GB hard cap, no swap). Measured 2026-07-16:
# the US road network is 427,002,681 nodes and osrm-extract is OOM-killed at
# 24 GB. Texas peaked at 7.28 GB and is ~1/12 of the US, so budget ~85 GB.
# 64 GB is documented to OOM on this exact file; 256 GB is documented to work.
set -euo pipefail

OSRM_IMAGE="osrm/osrm-backend:v5.25.0"
PBF_URL="https://download.geofabrik.de/north-america/us-latest.osm.pbf"
D=/mnt/osrm
mkdir -p "$D"
cd "$D"

echo "==> Free disk (need ~100 GB):"
df -h "$D" | tail -1
echo "==> RAM (need ~85 GB peak for extract):"
free -g | head -2

if ! command -v docker >/dev/null; then
  echo "==> Installing docker"
  curl -fsSL https://get.docker.com | sh
fi

if [ ! -f "$D/us-latest.osm.pbf" ]; then
  echo "==> Downloading US extract (~11 GB)"
  # .part + mv so an interrupted download can never look like a finished one.
  curl -fL -C - --retry 3 -o "$D/us-latest.osm.pbf.part" "$PBF_URL"
  mv "$D/us-latest.osm.pbf.part" "$D/us-latest.osm.pbf"
fi
ls -lh "$D/us-latest.osm.pbf"

# Each stage prints "RAM: peak bytes used" at the end. Watch those -- they are
# the ground truth for what this actually needs, and they were sitting in the
# Railway logs unread for a whole morning.
run() { docker run --rm -t -v "$D:/data" "$OSRM_IMAGE" "$@"; }

echo "==> osrm-extract   (the big one; expect ~85 GB peak, 45-90 min)"
time run osrm-extract -p /opt/car.lua /data/us-latest.osm.pbf

echo "==> osrm-partition (~20-30 min)"
time run osrm-partition /data/us-latest.osrm

echo "==> osrm-customize (~20-30 min)"
time run osrm-customize /data/us-latest.osrm

echo "==> Build complete."
du -sh "$D"/us-latest.osrm* | tail -1
df -h "$D" | tail -1
echo "Next: bash table-query.sh"
