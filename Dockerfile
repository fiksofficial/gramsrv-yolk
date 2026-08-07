# ----------------------------------
# Pelican Panel Dockerfile
# Environment: Go 1.25 + bundled PostgreSQL 16 + Redis (Debian bookworm)
# Purpose: all-in-one Yolk for gramsrv (telesrv) -- bundles PostgreSQL and
#          Redis in the SAME container so the egg has no external
#          dependencies. Used for both the install step and the runtime.
# Minimum Panel Version: 1.0.0
# ----------------------------------
FROM        --platform=$TARGETOS/$TARGETARCH golang:1.25-bookworm

LABEL       org.opencontainers.image.authors="you@example.com" \
            org.opencontainers.image.source="https://github.com/iamxvbaba/gramsrv" \
            org.opencontainers.image.licenses=MIT \
            org.opencontainers.image.description="All-in-one Yolk for gramsrv (telesrv): Go build toolchain + bundled PostgreSQL + Redis baked into one image, so the egg boots without any external database services."

RUN         apt-get update -y \
            && apt-get install -y --no-install-recommends \
                git \
                ca-certificates \
                curl \
                tini \
                postgresql \
                postgresql-contrib \
                redis-server \
            && PGVER="$(ls /usr/lib/postgresql)" \
            && ln -s /usr/lib/postgresql/${PGVER}/bin/* /usr/local/bin/ \
            && rm -rf /var/lib/apt/lists/*
            # postgresql/postgresql-contrib/redis-server are baked into the
            # IMAGE itself (not installed by the egg's install script) --
            # that's what makes them survive into the runtime container.
            # The symlink puts initdb/pg_ctl/pg_isready/psql/createdb on
            # PATH regardless of the Debian package's versioned bin dir.

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
