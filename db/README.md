# db/

Database bootstrap and tests for riptide. The **schema itself lives in Alembic
migrations** (`../migrations/`), which are the source of truth; this folder holds
the one-time bootstrap and the security test suite. One database holds metadata,
ACLs, vectors (pgvector) and full-text search.

## Files

| File | Purpose |
| --- | --- |
| `bootstrap.sql` | Extensions (`vector`, `pgcrypto`) and roles. Run once, as a superuser. Prerequisite for migrations. |
| `test_security.sql` | 28 tests: isolation, permissions, versioning, model lifecycle. |
| `run_tests.sh` | Rebuilds a throwaway DB, runs `alembic upgrade head`, runs the tests. |

The actual DDL (tables, composite FKs, RLS policies, triggers, functions) is in
`../migrations/versions/0001_initial_up.sql`, applied by migration `0001_initial`.

## Schema changes

Add a migration — never hand-edit a live DB or the frozen baseline SQL:

```bash
uv run alembic revision -m "add xyz"     # then write raw SQL in op.execute(...)
uv run alembic upgrade head
```

Then add a test to `test_security.sql` proving both the allowed and denied path,
and re-run the suite.

## Running the tests

```bash
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres ./db/run_tests.sh
```

Requires a Postgres **with pgvector ≥ 0.8** (use `pgvector/pgvector:pg16`). The
schema is built by Alembic as the non-superuser owner (`riptide_owner`) so
`FORCE ROW LEVEL SECURITY` is exercised exactly as in production; assertions run
as `riptide_api` / `riptide_worker` with `app.tenant_id` / `app.user_id` set per
the app's request path. This tests the real migration path you deploy.

## Roles

- `riptide_owner` — owns the schema, runs migrations. **Never used by the app.**
- `riptide_api` — request path: reads only permitted rows, can't modify chunks,
  audit log is insert-only.
- `riptide_worker` — ingestion path: full read/write within its tenant.
- `*_login` — the login roles the app actually connects as (members of the above).

## Invariants (do not weaken — add a test for every rule)

- Every tenant-owned table: `tenant_id`, `UNIQUE (tenant_id, id)`, composite FKs,
  `ENABLE` + `FORCE ROW LEVEL SECURITY`, a tenant-isolation policy.
- A missing `app.tenant_id` returns zero rows (fail closed).
- Collections are the permission boundary; grants are additive (no denies);
  clearance is a separate, non-inherited gate.
- Chunks carry an ACL snapshot kept in sync by triggers; retrieval filters on it
  inside the query (before ranking), so search can never leak.
