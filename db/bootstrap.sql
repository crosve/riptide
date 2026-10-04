-- Roles and extensions for riptide. Runs as a superuser (migration bootstrap only).
-- The application NEVER connects as a superuser or as the schema owner; it connects
-- as a *_login role that is a member of the non-login group role riptide_api /
-- riptide_worker. Group roles carry the privileges; login roles carry credentials.

-- Extensions (superuser-only) ------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector (>= 0.8)
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digests

-- Group roles ----------------------------------------------------------------
DO $$
BEGIN
  -- Owns the schema and runs migrations (Alembic connects as this role). NON-superuser
  -- on purpose so FORCE RLS also applies to it; the app never connects as this role.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'riptide_owner') THEN
    CREATE ROLE riptide_owner LOGIN PASSWORD 'owner_pw';
  END IF;

  -- Request path: read-only over permitted rows, insert-only audit, no chunk writes.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'riptide_api') THEN
    CREATE ROLE riptide_api NOLOGIN;
  END IF;

  -- Ingestion path: full read/write within the tenant it is scoped to.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'riptide_worker') THEN
    CREATE ROLE riptide_worker NOLOGIN;
  END IF;

  -- Login roles (credentials) -------------------------------------------------
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'riptide_api_login') THEN
    CREATE ROLE riptide_api_login LOGIN PASSWORD 'api_pw' IN ROLE riptide_api;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'riptide_worker_login') THEN
    CREATE ROLE riptide_worker_login LOGIN PASSWORD 'worker_pw' IN ROLE riptide_worker;
  END IF;
END $$;

-- Ensure the owner can log in (Alembic migration identity), even on a cluster
-- where the role predates this change.
ALTER ROLE riptide_owner LOGIN PASSWORD 'owner_pw';

-- Let the owner role own the current database's public schema so migrations can
-- create objects there as riptide_owner.
ALTER SCHEMA public OWNER TO riptide_owner;
GRANT USAGE ON SCHEMA public TO riptide_api, riptide_worker;
