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
    initdb -D "${PGDATA}" -U "${PG_LOCAL_USER}" --pwfile="${PWFILE}" --encoding=UTF8 --locale=C.UTF-8 --auth=scram-sha-256 --auth-local=trust >/home/container/logs/pg-initdb.log 2>&1
    rm -f "${PWFILE}"
fi

# Debian's postgresql.conf defaults unix_socket_directories to
# /var/run/postgresql, which doesn't exist (and wouldn't be writable) for
# the non-root 'container' user -- postgres FATALs on every single boot
# before ever accepting a connection otherwise. Nothing here needs a Unix
# socket: every psql/pg_isready/createdb call below connects over TCP
# (-h 127.0.0.1). Checked unconditionally (not just on first init) so an
# existing PGDATA from before this fix self-heals on the next boot too.
grep -q "^unix_socket_directories" "${PGDATA}/postgresql.conf" 2>/dev/null || \
    echo "unix_socket_directories = ''" >> "${PGDATA}/postgresql.conf"

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
# Optional admin backend (cmd/telesrv-admin).
# Verified directly against cmd/telesrv-admin/main.go: it opens its own pgx
# pool straight at TELESRV_POSTGRES_DSN (reuses the bundled Postgres above,
# no separate DB needed), and calls telesrv's in-process Admin API for writes
# -- which telesrv itself only opens when TELESRV_ADMIN_API_ADDR is non-empty
# (its own default is empty/disabled). loadConfig() in that file hard-fails
# startup unless AdminUIPassword-or-AdminUIToken, AdminAPIToken, and
# AdminSessionKey are all set -- mirrored by the checks below so a bad config
# just skips the feature instead of crash-looping in the background.
# ---------------------------------------------------------------------------
if [ "${ENABLE_ADMIN_BACKEND:-false}" = "true" ]; then
    mkdir -p /home/container/data

    # telesrv's own Admin API default is empty (disabled) -- must be non-empty
    # for telesrv-admin to have anything to call.
    export TELESRV_ADMIN_API_ADDR="${TELESRV_ADMIN_API_ADDR:-127.0.0.1:2599}"

    # Shared bearer secret between telesrv (API) and telesrv-admin (caller) --
    # opaque to a human, so auto-generate and persist it on first boot unless
    # you've pinned one yourself via the Panel Variable.
    if [ -z "${TELESRV_ADMIN_API_TOKEN:-}" ]; then
        [ -s /home/container/data/.admin_api_token ] || (umask 077 && head -c32 /dev/urandom | base64 | tr -d '\n' > /home/container/data/.admin_api_token)
        export TELESRV_ADMIN_API_TOKEN="$(cat /home/container/data/.admin_api_token)"
    fi

    # Signs/encrypts telesrv-admin's session cookies -- also opaque, same
    # auto-generate-and-persist treatment. Changing it invalidates sessions.
    if [ -z "${TELESRV_ADMIN_SESSION_KEY:-}" ]; then
        [ -s /home/container/data/.admin_session_key ] || (umask 077 && head -c32 /dev/urandom | base64 | tr -d '\n' > /home/container/data/.admin_session_key)
        export TELESRV_ADMIN_SESSION_KEY="$(cat /home/container/data/.admin_session_key)"
    fi

    if [ ! -x /home/container/gramsrv-admin ]; then
        echo "-- ENABLE_ADMIN_BACKEND=true but gramsrv-admin wasn't built successfully at install time, skipping --"
    elif [ -z "${TELESRV_ADMIN_UI_PASSWORD:-}" ] && [ -z "${TELESRV_ADMIN_UI_TOKEN:-}" ]; then
        echo "-- ENABLE_ADMIN_BACKEND=true but no login credential is set -- fill in 'Admin UI Password', or set TELESRV_ADMIN_UI_TOKEN in extra.env, skipping --"
    else
        echo "-- starting telesrv-admin on ${TELESRV_ADMIN_UI_ADDR:-127.0.0.1:2600} (telesrv Admin API at ${TELESRV_ADMIN_API_ADDR}) --"
        (./gramsrv-admin > /home/container/logs/admin.log 2>&1 &)
    fi
fi

echo "== bundled services ready, launching gramsrv =="

# Replace startup placeholders ({{VAR}} -> $VAR) and run the resolved command.
# Wings injects STARTUP with {{...}} placeholders still in it -- leave this
# substitution logic as-is; it's generic across every runtime.
MODIFIED_STARTUP=`eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')`
echo ":/home/container$ ${MODIFIED_STARTUP}"

exec ${MODIFIED_STARTUP}
