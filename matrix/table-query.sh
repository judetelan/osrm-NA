#!/usr/bin/env bash
# Run ON THE DROPLET after build-us.sh. Starts osrm-routed, asks for the full
# 445x445 road-distance matrix in ONE /table call, writes matrix.csv, stops.
# Takes a couple of minutes. points.csv must be in this directory.
set -euo pipefail

OSRM_IMAGE="osrm/osrm-backend:v5.25.0"
D=/mnt/osrm
HERE="$(cd "$(dirname "$0")" && pwd)"
N=$(( $(wc -l < "$HERE/points.csv") - 1 ))
echo "==> $N points -> $(( N * N )) pairs"

# max-table-size must be >= N or OSRM refuses the request with TooBig.
docker rm -f osrm-tbl >/dev/null 2>&1 || true
docker run -d --name osrm-tbl -p 5000:5000 -v "$D:/data" "$OSRM_IMAGE" \
  osrm-routed --algorithm mld --max-table-size 1000 /data/us-latest.osrm

echo "==> Waiting for osrm-routed to load the graph (can take a few minutes)"
for i in $(seq 1 120); do
  if curl -sf "http://localhost:5000/route/v1/driving/-95.607,29.6196;-95.3698,29.7604?overview=false" \
       | grep -q '"code":"Ok"'; then echo "    up after ${i}0s"; break; fi
  sleep 10
  [ "$i" = 120 ] && { echo "TIMED OUT"; docker logs --tail 40 osrm-tbl; exit 1; }
done

# Sanity check BEFORE trusting 198k numbers: Sugar Land -> Houston is ~22 mi by
# road. If this is wildly off, the graph is bad and the matrix is worthless.
echo "==> Sanity check, plant -> downtown Houston (expect ~20-25 mi):"
curl -s "http://localhost:5000/route/v1/driving/-95.607,29.6196;-95.3698,29.7604?overview=false" \
  | python3 -c "import sys,json; print('   %.1f mi' % (json.load(sys.stdin)['routes'][0]['distance']/1609.344))"

echo "==> Requesting the full matrix"
python3 - "$HERE/points.csv" "$HERE/matrix.csv" <<'PY'
import csv, json, sys, urllib.request
src, dst = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(src, newline='')))
ids  = [r['id'] for r in rows]
coords = ";".join(f"{r['lng']},{r['lat']}" for r in rows)
url = f"http://localhost:5000/table/v1/driving/{coords}?annotations=distance"
print(f"   {len(ids)} coords, one request")
d = json.load(urllib.request.urlopen(url, timeout=1800))
if d.get("code") != "Ok":
    sys.exit(f"OSRM said: {d}")
M = d["distances"]
null = 0
with open(dst, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["from_zip", "to_zip", "road_mi"])
    for i, a in enumerate(ids):
        for j, b in enumerate(ids):
            if i == j:
                continue
            v = M[i][j]
            if v is None:      # unroutable pair; leave it out, caller falls back
                null += 1
                continue
            w.writerow([a, b, round(v / 1609.344, 2)])
print(f"   wrote {dst}")
print(f"   unroutable pairs skipped: {null}")
PY

docker rm -f osrm-tbl >/dev/null
echo "==> Done. matrix.csv:"
ls -lh "$HERE/matrix.csv"
head -3 "$HERE/matrix.csv"
echo ""
echo "Copy it down, then DESTROY THE DROPLET:"
echo "  scp root@<IP>:$HERE/matrix.csv ."
