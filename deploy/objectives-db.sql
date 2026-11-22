-- The objectives store's role and database (ObsFactor.Objectives). Run once,
-- by a human, on the box:
--
--   cd /opt/blog && set -a && . ./.env && set +a && \
--   docker compose exec -T db psql -U blog -d postgres -v ON_ERROR_STOP=1 \
--     -v pw="$OBS_FACTOR_OBJECTIVES_DB_PASSWORD" < /opt/obs_factor/deploy/objectives-db.sql
--
-- and give the observer
--   OBJECTIVES_PG_URL=postgres://obs_factor_app:<pw>@db/obs_factor
-- (hex password, openssl rand -hex 24: it sits in the URL unescaped).
-- Unset, the observer runs without objectives and /api/objectives answers
-- 503 "no objectives store".
--
-- Why a role and database of their own, not the `obs_factor` monitor role
-- (deploy/postgres-role.sql): that one is read-only on purpose and limited
-- to one connection. This one writes, so it gets a database it owns and
-- nothing else:
-- - CONNECTION LIMIT 2: the store's pool is two connections
--   (Objectives.child_specs, pool_size: 2); a third is refused by the server.
--   On a box near max_connections these two come out of the ordinary slots,
--   the same trade-off README "Postgres" describes for the monitor role.
-- - CREATE DATABASE ... OWNER: the tables are created at start
--   (CREATE TABLE IF NOT EXISTS) by the role that owns the database.
-- - REVOKE CONNECT FROM PUBLIC: no other role connects to it by default.
--   Superusers still can.
-- CREATE DATABASE cannot run in a transaction: do not wrap this file in one.

CREATE ROLE obs_factor_app LOGIN CONNECTION LIMIT 2 PASSWORD :'pw';
CREATE DATABASE obs_factor OWNER obs_factor_app;
REVOKE CONNECT ON DATABASE obs_factor FROM PUBLIC;
GRANT CONNECT ON DATABASE obs_factor TO obs_factor_app;
