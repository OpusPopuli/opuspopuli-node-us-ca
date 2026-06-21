-- Set passwords on supabase roles created by the image's bundled init.
--
-- Diverges from upstream's roles.sql in one place: each ALTER is wrapped
-- in a `pg_roles` existence check. Upstream assumes every role exists by
-- this point in init, but supabase_functions_admin is created LAZILY by
-- the post-setup event trigger ONLY when the pg_net extension is later
-- installed — at the moment this script runs, it doesn't exist yet, and
-- a naïve ALTER USER under ON_ERROR_STOP=1 halts the rest of the init
-- chain. Each role we ALTER is created by the image's earlier scripts
-- (00000000000000-initial-schema.sql + 00000000000001-auth-schema.sql +
-- 00000000000002-storage-schema.sql), so the EXISTS check is a no-op for
-- the vast majority — it's only there to skip the functions_admin case
-- without aborting.
\set pgpass `echo "$POSTGRES_PASSWORD"`
SELECT set_config('opuspopuli.pgpass', :'pgpass', false);

DO $$
DECLARE
  pw text := current_setting('opuspopuli.pgpass');
  role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY[
    'authenticator',
    'pgbouncer',
    'supabase_auth_admin',
    'supabase_functions_admin',
    'supabase_storage_admin'
  ]
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
      EXECUTE format('ALTER USER %I WITH PASSWORD %L', role_name, pw);
    END IF;
  END LOOP;
END
$$;

-- Clear the pgpass GUC so it doesn't linger in session state.
SELECT set_config('opuspopuli.pgpass', '', false);
