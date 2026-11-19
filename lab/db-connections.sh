#!/bin/bash
set -euo pipefail

# Hold N idle Postgres connections, to put the lab where the box was on
# 2026-11-18 (96 of 100). The lab runs max_connections=30, so
#
#   lab/db-connections.sh 26          ~27-28 of 30 with the observer's one
#   lab/db-connections.sh 26 600      ... held for 600 s (default 300)
#
# Ctrl-C releases them. Each is a real backend in pg_stat_activity and counts
# in pg_stat_database.numbackends for lab_blog.
#
# Past max_connections minus superuser_reserved_connections (3), a
# non-superuser (the observer's obs_factor role) is refused with "remaining
# connection slots are reserved"; the superuser `blog` used here is not.

N="${1:?how many connections}"
SECS="${2:-300}"
C=obslab-db-1

# Killing a `docker exec` client does not kill the psql inside the container,
# so release means terminating the backends by what they are running.
release() {
  trap - EXIT INT TERM
  docker exec "$C" psql -U blog -d postgres -qtAc \
    "select count(pg_terminate_backend(pid)) || ' released' from pg_stat_activity where query = 'select pg_sleep($SECS)' and pid <> pg_backend_pid()"
  kill "${pids[@]}" 2>/dev/null || true
}
pids=()
trap release EXIT INT TERM
for _ in $(seq 1 "$N"); do
  docker exec "$C" psql -U blog -d lab_blog -qtAc "select pg_sleep($SECS)" >/dev/null 2>&1 &
  pids+=($!)
done
sleep 2
docker exec "$C" psql -U blog -d postgres -tAc \
  "select count(*) || ' of ' || current_setting('max_connections') || ' connections in use' from pg_stat_activity where backend_type = 'client backend'"
wait
