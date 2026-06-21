-- =============================================================================
-- 00-create-supabase-admin.sql — bootstrap `supabase_admin` for migrate.sh
-- =============================================================================
--
-- This file is mounted at /docker-entrypoint-initdb.d/00-create-supabase-admin.sql
-- (TOP LEVEL, not init-scripts/) so the standard postgres docker-entrypoint
-- runs it BEFORE the image's bundled migrate.sh.
--
-- Why this exists:
-- The supabase/postgres image's migrate.sh expects `supabase_admin` to
-- already exist. In its AMI build path, supabase_admin is pre-created
-- during image construction (see comment at the top of migrate.sh:
-- "postgres role is pre-created during AMI build"). On a Docker
-- deployment with a fresh named volume, `initdb` runs from scratch and
-- only the `postgres` role exists — migrate.sh's very first `psql -U
-- supabase_admin` then fails with FATAL: role "supabase_admin" does not
-- exist, halting before its init-scripts loop can run anything useful.
--
-- We pre-create supabase_admin here. The standard entrypoint runs us as
-- `postgres` (which exists after initdb) connected to POSTGRES_DB, and
-- migrate.sh later sets the password via `ALTER USER supabase_admin WITH
-- PASSWORD …`. We don't set a password here.
--
-- Naming: `00-…` sorts alphabetically before `migrate.sh`, which is the
-- only other .sh/.sql file at the top level of /docker-entrypoint-initdb.d/.
-- =============================================================================

CREATE ROLE supabase_admin
  WITH SUPERUSER CREATEDB CREATEROLE INHERIT LOGIN BYPASSRLS REPLICATION;
