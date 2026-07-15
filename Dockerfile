# syntax=docker/dockerfile:1
# OSRM routing server for the whole US, self-contained for Railway.
# Same image builds the map (osrm-extract/partition/customize) and serves it
# (osrm-routed). The heavy build runs at RUNTIME in entrypoint.sh (not in the
# Docker build), so it has the mounted volume and won't hit build timeouts.
FROM ghcr.io/project-osrm/osrm-backend:v26.7.3

# We need a downloader at runtime for the OSM extract. Modern OSRM images are
# Debian-based; only run apt if curl isn't already present, so we never touch apt
# on an image that already ships it.
RUN if ! command -v curl >/dev/null 2>&1; then \
      apt-get update \
      && apt-get install -y --no-install-recommends curl ca-certificates \
      && rm -rf /var/lib/apt/lists/*; \
    fi

COPY entrypoint.sh /entrypoint.sh
# Strip any CR (in case the file was saved with Windows line endings) and mark exec.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 5000
ENTRYPOINT ["/entrypoint.sh"]
