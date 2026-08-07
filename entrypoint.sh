#!/bin/bash
cd /home/container

echo "== gramsrv (telesrv) all-in-one container: bootstrapping bundled services =="

# ---------------------------------------------------------------------------
# Optional user-supplied extra environment.
# Edit this file from the Panel's file manager to add anything this egg
# doesn't expose as a Variable -- SMTP, AI providers, TURN/SFU, Telegram
# Login, or settings for the optional admin backend below. Real key names
# come from the project's own docs/configuration.en.md.
# ---------------------------------------------------------------------------
if [ -f /home/container/extra.env ]; then
    echo "-- loading extra.env --"
    set -a
    # shellcheck disable=SC1091
    source /home/container/extra.env
    set +a
fi

mkdir -p /home/container/logs

# ---------------------------------------------------------------------------
# Bundled PostgreSQL -- matches the default TELESRV_POSTGRES_DSN below
# (user/db "telesrv", port 5432, localhost). If you point that variable at
# an external database instead, this local instance still starts but is
# simply unused.
# ---------------------------------------------------------------------------
export PGDATA=/home/container/pgdata
PG_LOCAL_PORT=5432
PG_LOCAL_USER=telesrv
PG_LOCAL_PASSWORD=telesrv
PG_LOCAL_DB=telesrv

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    echo "-- first boot: initializing bundled PostgreSQL data directory --"
    mkdir -p "${PGDATA}"
    PWFILE="$(mktemp)"
    echo "${PG_LOCAL_PASSWORD}" > "${PWFILE}"
    initdb -D "${PGDATA}" -U "${PG_LOCAL_USER}" --pwfile="${PWFILE}" --auth=scram-sha-256 --auth-local=trust >/home/container/logs/pg-initdb.log 2>&1
    rm -f "${PWFILE}"
fi

echo "-- starting bundled PostgreSQL on 127.0.0.1:${PG_LOCAL_PORT} --"
pg_ctl -D "${PGDATA}" -l /home/container/logs/postgres.log -o "-p ${PG_LOCAL_PORT} -h 127.0.0.1" -w start

for i in $(seq 1 30); do
    pg_isready -h 127.0.0.1 -p "${PG_LOCAL_PORT}" -q && break
    sleep 1
done

EXISTS=$(psql -h 127.0.0.1 -p "${PG_LOCAL_PORT}" -U "${PG_LOCAL_USER}" -tAc "SELECT 1 FROM pg_database WHERE datname = '${PG_LOCAL_DB}'" postgres 2>>/home/container/logs/postgres.log)
if [ "${EXISTS}" != "1" ]; then
    echo "-- creating database '${PG_LOCAL_DB}' --"
    createdb -h 127.0.0.1 -p "${PG_LOCAL_PORT}" -U "${PG_LOCAL_USER}" "${PG_LOCAL_DB}"
fi

# ---------------------------------------------------------------------------
# Bundled Redis -- matches the default TELESRV_REDIS_ADDR below
# (127.0.0.1:6399). TELESRV_REDIS_PASSWORD, if set, both configures this
# local instance's requirepass AND is what gramsrv authenticates with.
# ---------------------------------------------------------------------------
REDIS_LOCAL_PORT=6399
mkdir -p /home/container/redisdata

cat > /home/container/redis.conf <<EOF
port ${REDIS_LOCAL_PORT}
bind 127.0.0.1
dir /home/container/redisdata
daemonize no
appendonly yes
EOF
if [ -n "${TELESRV_REDIS_PASSWORD:-}" ]; then
    echo "requirepass ${TELESRV_REDIS_PASSWORD}" >> /home/container/redis.conf
fi

echo "-- starting bundled Redis on 127.0.0.1:${REDIS_LOCAL_PORT} --"
redis-server /home/container/redis.conf --daemonize yes --pidfile /home/container/redis.pid --logfile /home/container/logs/redis.log

# ---------------------------------------------------------------------------
# TURN (12400 + relay range 12500-12999/udp) and SFU (12399/udp) default to
# ENABLED in gramsrv itself (internal/config/config.go), and each does a
# net.ListenUDP on its own port at startup -- if that UDP port isn't actually
# reachable/allocated on this node, gramsrv's startup FAILS outright, not just
# the calling feature (private/group calls). A single-allocation Pelican node
# normally can't open a ~500-port UDP range, so this egg turns both off by
# default here unless the operator already opted in via the Panel Variables
# below (TURN_ENABLE / SFU_ENABLE) -- which requires the matching UDP ports to
# actually be allocated on the node first. See docs/configuration.en.md section
# 11 in the gramsrv repo for the full port/firewall requirements before
# enabling either one.
export TELESRV_TURN_ENABLE="${TELESRV_TURN_ENABLE:-false}"
export TELESRV_SFU_ENABLE="${TELESRV_SFU_ENABLE:-false}"

# ---------------------------------------------------------------------------
# Optional admin backend (cmd/telesrv-admin), best-effort.
# Only starts if the install script managed to build it AND you've opted in.
# It reads whatever you put in extra.env -- this egg doesn't know its real
# variable names, so configure it there.
# ---------------------------------------------------------------------------
if [ "${ENABLE_ADMIN_BACKEND:-false}" = "true" ]; then
    if [ -x /home/container/gramsrv-admin ]; then
        echo "-- starting telesrv-admin in background (see extra.env for its settings) --"
        (./gramsrv-admin > /home/container/logs/admin.log 2>&1 &)
    else
        echo "-- ENABLE_ADMIN_BACKEND=true but gramsrv-admin was not built successfully at install time, skipping --"
    fi
fi

echo "== bundled services ready, launching gramsrv =="

# Replace startup placeholders ({{VAR}} -> $VAR) and run the resolved command.
# Wings injects STARTUP with {{...}} placeholders still in it -- leave this
# substitution logic as-is; it's generic across every runtime.
MODIFIED_STARTUP=`eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')`
echo ":/home/container$ ${MODIFIED_STARTUP}"

exec ${MODIFIED_STARTUP}
