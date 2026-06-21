-- =============================================================================
-- 05-app-extensions.sql — install extensions our backend Prisma schema needs
-- =============================================================================
--
-- The supabase/postgres image bundles PostGIS, pgvector, and pg_trgm but
-- doesn't auto-enable them in the default database. Our backend Prisma
-- schema references `geography(Point, 4326)` (PostGIS), `vector(N)`
-- (pgvector) and `pg_trgm` operators, so the Prisma migrate fails with
-- "type 'geography' does not exist" if these aren't created first.
--
-- Why this runs in init-scripts (not via db-migrate.sh in the backend):
-- After all bundled migrations finish, the image's
-- `10000000000000_demote-postgres.sql` strips SUPERUSER from the
-- `postgres` role. CREATE EXTENSION for PostGIS / pgvector requires
-- SUPERUSER. db-migrate runs as `postgres` AFTER the demote → can't
-- install these.
--
-- Running here means we install while `postgres` is still SUPERUSER
-- (init-scripts run BEFORE migrate.sh's migrations loop, which is
-- where demote-postgres lives). Each is `IF NOT EXISTS` so this is
-- idempotent across image upgrades that might pre-install one.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis    WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm    WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS vector     WITH SCHEMA extensions;
