-- =============================================================================
-- 00-opuspopuli-roles.sql — defensive supabase_admin creation
-- =============================================================================
--
-- The `supabase/postgres` image normally creates the `supabase_admin` role
-- via its bundled init scripts. In our compose configuration (POSTGRES_USER
-- = postgres, POSTGRES_DB = opuspopuli) we've observed cases where those
-- scripts don't run before our migration scripts try to use the role.
-- Result: db-migrate fails with `ERROR: role "supabase_admin" does not exist`
-- and silently skips every extension install + the Prisma baseline migration
-- can't apply.
--
-- This file is mounted FIRST (00- prefix) into /docker-entrypoint-initdb.d/
-- so it runs before any other supabase init script that depends on
-- supabase_admin existing.
--
-- IF EXISTS guard means re-runs (after image upgrades, etc.) are no-ops.
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin WITH SUPERUSER CREATEDB CREATEROLE INHERIT LOGIN BYPASSRLS REPLICATION;
  END IF;
END
$$;
