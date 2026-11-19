#!/bin/bash
set -euo pipefail

# Make one lab database busy with real transactions (pgbench, which ships in
# the postgres image), so its xact_commit in pg_stat_database climbs and the
# app -> db belt moves.
#
#   lab/db-busy.sh                    lab_links, 2 clients, 60 s
#   lab/db-busy.sh lab_blog 4 300     database, clients, seconds
#
# Initialises pgbench's tables in that database the first time (they are the
# only thing in it, so its size in `holds` grows by ~15 MB too).

DB="${1:-lab_links}"
CLIENTS="${2:-2}"
SECS="${3:-60}"
C=obslab-db-1

docker exec "$C" psql -U blog -d "$DB" -tAc "select 1 from pg_tables where tablename='pgbench_accounts'" | grep -q 1 \
  || docker exec "$C" pgbench -U blog -i -q -s 1 "$DB"

# -R caps the rate so a laptop is not pinned; remove it to see a hot database.
echo "pgbench on $DB: $CLIENTS clients, $SECS s, ~50 tps"
docker exec "$C" pgbench -U blog -c "$CLIENTS" -T "$SECS" -R 50 -P 10 "$DB"
