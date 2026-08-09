# ----------------------------------
# Pelican Panel Dockerfile
# Environment: Go 1.25 + bundled PostgreSQL + Redis + ffmpeg (Debian bookworm)
# Purpose: all-in-one Yolk for gramsrv (telesrv) -- bundles PostgreSQL and
#          Redis in the SAME container so the egg has no external
#          dependencies. Used for both the install step and the runtime.
# Minimum Panel Version: 1.0.0
#
# Verified against the actual gramsrv-main source (cmd/telesrv/main.go,
# internal/config/config.go, docs/configuration.en.md):
#   - ffmpeg is required for TELESRV_LIVESTREAM_ENABLE=true (default true);
#     internal/app/livestream/segmenter.go shells out to it directly. Startup
#     itself never fails without it -- only an actual OBS stream attempt does.
#   - TURN (12400 + relay range 12500-12999/udp) and SFU (12399/udp) are both
#     enabled by default and net.ListenUDP on their own ports; if those UDP
#     ports aren't reachable in this container, START-UP ITSELF FAILS, not
#     just the calling feature. The entrypoint below disables both by default
#     (TELESRV_TURN_ENABLE=false, TELESRV_SFU_ENABLE=false) since a typical
#     single-allocation Pelican node can't usually open a ~500-port UDP range;
#     an operator who wants voice/video calls can flip them on in extra.env
#     once those ports are actually allocated on the node.
# ----------------------------------
FROM        --platform=$TARGETOS/$TARGETARCH golang:1.25-bookworm

LABEL       org.opencontainers.image.authors="you@example.com" \
            org.opencontainers.image.source="https://github.com/iamxvbaba/gramsrv" \
            org.opencontainers.image.licenses=MIT \
            org.opencontainers.image.description="All-in-one Yolk for gramsrv (telesrv): Go build toolchain + bundled PostgreSQL + Redis + ffmpeg baked into one image, so the egg boots without any external database services."

RUN         apt-get update -y \
            && apt-get install -y --no-install-recommends \
                git \
                ca-certificates \
                curl \
                gnupg \
                tini \
                redis-server \
                ffmpeg \
            # Debian bookworm's own repo only ships PostgreSQL 15. gramsrv's
            # baseline migration (deploy/migrations/0001_init.up.sql) is a
            # pg_dump 17.10 snapshot that SETs transaction_timeout, a GUC
            # that doesn't exist before PG17 -- applying it against 15 fails
            # with "unrecognized configuration parameter". Upstream's own
            # docker-compose.yml confirms: postgres:17-alpine. Add the
            # official PGDG apt repo to get 17 specifically on Debian.
            && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
            && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
            && apt-get update -y \
            && apt-get install -y --no-install-recommends postgresql-17 postgresql-contrib-17 \
            && PGVER="$(ls /usr/lib/postgresql)" \
            && ln -s /usr/lib/postgresql/${PGVER}/bin/* /usr/local/bin/ \
            && rm -rf /var/lib/apt/lists/*
            # postgresql-17/postgresql-contrib-17/redis-server are baked into
            # the IMAGE itself (not installed by the egg's install script) --
            # that's what makes them survive into the runtime container.
            # The symlink puts initdb/pg_ctl/pg_isready/psql/createdb on
            # PATH regardless of the Debian package's versioned bin dir.
            # ffmpeg is required by TELESRV_LIVESTREAM_ENABLE (default true) --
            # see internal/app/livestream/segmenter.go, which shells out to the
            # binary named by TELESRV_LIVESTREAM_FFMPEG_PATH (default "ffmpeg",
            # resolved through PATH).

## Setup user and working directory -- these exact names are required
RUN         useradd -m -d /home/container -s /bin/bash container
USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

STOPSIGNAL  SIGTERM

COPY        --chown=container:container ./entrypoint.sh /entrypoint.sh
RUN         chmod +x /entrypoint.sh

ENTRYPOINT  ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
