# syntax=docker/dockerfile:1
# OSRM routing server for the whole US, self-contained for Railway.
# Same image builds the map (osrm-extract/partition/customize) and serves it
# (osrm-routed). The heavy build runs at RUNTIME in entrypoint.sh (not in the
# Docker build), so it has the mounted volume and won't hit build timeouts.
# OSRM's newest prebuilt Docker image is v5.25.0 (Debian stretch, now end-of-life),
# so we repoint apt at the Debian archive to install curl. Routing quality is
# equivalent to newer releases for car routing on current OSM data; the same image
# builds the map and serves it, so version consistency is guaranteed.
FROM osrm/osrm-backend:v5.25.0

RUN set -eux; \
    printf 'deb http://archive.debian.org/debian stretch main\ndeb http://archive.debian.org/debian-security stretch/updates main\n' > /etc/apt/sources.list; \
    apt-get -o Acquire::Check-Valid-Until=false update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
# Strip any CR (in case the file was saved with Windows line endings) and mark exec.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 5000
ENTRYPOINT ["/entrypoint.sh"]
