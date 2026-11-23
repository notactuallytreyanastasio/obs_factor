-- Runs once, on the first boot of an empty data volume
-- (docker-entrypoint-initdb.d). `docker compose down -v` to run it again.
--
-- Two app databases, like blog_prod and blinks_backend_prod, owned by the
-- superuser `blog` exactly as on the box.
CREATE DATABASE lab_blog;
CREATE DATABASE lab_links;

-- The observer's role: what deploy/postgres-role.sql proposes for production.
-- pg_monitor (which includes pg_read_all_stats) is what lets it read every
-- row of pg_stat_database and call pg_database_size() on databases it has no
-- CONNECT grant on. CONNECTION LIMIT 1 makes "the observer holds exactly one
-- connection" a fact the server enforces, not a promise in the client.
CREATE ROLE obs_factor LOGIN PASSWORD 'obslab' CONNECTION LIMIT 1 IN ROLE pg_monitor;

-- The objectives store (OBJECTIVES_PG_URL): its own role and database, as
-- deploy/objectives-db.sql makes them in production. Lab-only password. A
-- lab whose volume predates this: run these three lines once as `blog`
-- (psql postgresql://blog:obslab@127.0.0.1:15433/postgres).
CREATE ROLE obs_factor_app LOGIN CONNECTION LIMIT 2 PASSWORD 'obslab';
CREATE DATABASE obs_factor OWNER obs_factor_app;
REVOKE CONNECT ON DATABASE obs_factor FROM PUBLIC;
