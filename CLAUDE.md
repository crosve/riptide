# riptide

FastAPI service. This file orients any contributor (human or AI) to the platform and the practices we hold to.

## Platform / stack

- **Language**: Python 3.12 (pinned in `.python-version`; `requires-python = ">=3.12"`).
- **Framework**: FastAPI with the `[standard]` extras (uvicorn, websockets, the `fastapi` CLI).
- **Package manager**: **uv** — the only supported one. Do not use `pip`, `poetry`, `pipenv`, or hand-edit `uv.lock`.
- **Runtime**: Docker via `docker compose`. Local non-Docker runs are supported for quick checks but Docker is the source of truth.
- **ASGI server**: uvicorn, run with `--reload` in development.
- **Queue**: **arq** (async, Redis-backed) for background jobs / the ingestion pipeline. Redis runs as a compose service; a `worker` service runs `arq app.worker.WorkerSettings`.
- **Database**: PostgreSQL 16 + pgvector (`pgvector/pgvector:pg16`, pgvector ≥ 0.8). One DB for metadata, ACLs, vectors and full-text search. Driver: **asyncpg** (request path), **psycopg** (migrations).
- **Migrations**: **Alembic**, hand-written raw-SQL migrations (no autogenerate — RLS/triggers/functions/roles can't be reflected). Migrations are the **source of truth** for the schema. They run as `riptide_owner` (dedicated login role); extensions + roles are bootstrapped separately by `db/bootstrap.sql` (superuser). Schema changes = a new migration, never hand-editing a live DB.
- **Security model**: multi-tenant with Postgres **Row-Level Security**. The app connects as least-privilege login roles (`riptide_api_login` / `riptide_worker_login`), never the owner or a superuser. Per request, `app.tenant_id` / `app.user_id` are set with `SET LOCAL` inside a transaction; a missing setting yields zero rows (fail closed). **Cross-tenant leakage is the worst possible bug** — never weaken this.

## Layout

```
app/
  __init__.py
  main.py          # FastAPI app instance + routes (see app/CLAUDE.md)
  worker.py        # arq WorkerSettings entrypoint
  tasks.py         # arq task functions (thin; call into services/)
  core/
    config.py      # env-driven settings (DB, Redis, auth secrets)
    db.py          # asyncpg pool (connects as riptide_api_login)
    security.py    # API-key generation + constant-time verification
    auth.py        # authn + per-request RLS context (the request_context dependency)
alembic.ini        # Alembic config (URL injected by migrations/env.py)
migrations/
  env.py           # connects as riptide_owner via MIGRATION_DATABASE_URL (psycopg)
  versions/
    0001_initial_schema.py     # baseline migration (runs the sibling .sql files)
    0001_initial_up.sql        # frozen schema: tables, composite FKs, RLS, triggers, functions
    0001_initial_down.sql      # teardown (leaves extensions/roles to bootstrap.sql)
db/
  bootstrap.sql    # roles + extensions (run as superuser, once; prerequisite for migrations)
  test_security.sql# 28 isolation/permission/versioning/model-lifecycle tests
  run_tests.sh     # rebuild a throwaway DB, `alembic upgrade head`, run the suite
scripts/
  seed_demo.py     # provision a demo tenant + print an API key / JWTs
  gen_erd.py       # regenerate the DB ERD diagram from the live schema
Dockerfile         # uv-based image (shared by api + worker + migrate)
compose.yaml       # dev runtime: api, worker, migrate, redis, postgres — bind-mounts ./app for hot reload
diagrams/          # draw.io diagrams, mirrors the module layout (see diagrams/README.md)
  system/          # cross-cutting (ingestion pipeline)
  db/              # ERD (generated) + conceptual data model (hand-authored)
.env.example       # config contract (every env key; dummy values) — real values live in Doppler
doppler.yaml       # pins project/config for `doppler run` (no secrets)
.dockerignore
pyproject.toml     # dependencies (edit via `uv add` / `uv remove`)
uv.lock            # locked versions — committed, never edited by hand
```

## Commands

| Task | Command |
| --- | --- |
| Run full stack (Docker, hot reload) | `docker compose up --build` |
| Stop detached run | `docker compose down` |
| Run locally | `uv sync && uv run fastapi dev app/main.py` |
| Add a dependency | `uv add <pkg>` |
| Remove a dependency | `uv remove <pkg>` |
| Sync env to lockfile | `uv sync` |
| Run a one-off command in the env | `uv run <cmd>` |
| Run DB security tests | `PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres ./db/run_tests.sh` |
| Seed a demo tenant + credentials | `PYTHONPATH=. uv run python scripts/seed_demo.py` |
| New migration (hand-written SQL) | `uv run alembic revision -m "describe change"` |
| Apply migrations | `uv run alembic upgrade head` |
| Roll back one migration | `uv run alembic downgrade -1` |
| Show current revision | `uv run alembic current` |
| Regenerate the DB ERD | `uv run python scripts/gen_erd.py` |
| Run with secrets injected | `doppler run -- <cmd>` (e.g. `doppler run -- docker compose up`) |
| Link repo to Doppler (once) | `doppler setup` (reads `doppler.yaml`) |

Alembic reads `MIGRATION_DATABASE_URL` (schema owner, `postgresql+psycopg://…`). In
Docker the one-shot `migrate` service applies migrations before api/worker start.
New migrations are **raw SQL via `op.execute(...)`** — do not rely on autogenerate.

The API serves on `http://localhost:8000`; interactive docs at `/docs`.

> DB tests need a reachable Postgres **with pgvector** on `PGHOST:PGPORT`. The
> compose `postgres` service provides one; if a local Postgres already owns port
> 5432 the published container port is shadowed — point `PGHOST`/`PGPORT` at
> whichever server has pgvector, or stop the local one.

## Clean practices

- **Dependencies**: add/remove only through `uv add` / `uv remove` so `pyproject.toml` and `uv.lock` stay in sync. Commit both. After changing dependencies, rebuild the image (`docker compose up --build`) — hot reload only covers code.
- **Keep it lean**: this is a base. Don't add dependencies, config, or abstractions until a concrete need exists. Prefer the standard library and FastAPI built-ins first.
- **Routes & structure**: see `app/CLAUDE.md` for code-level conventions.
- **No secrets in the repo**: configuration comes from environment variables. **Doppler is the source of truth** (`doppler run -- <cmd>`); `.env.example` is the committed contract, `.env` is git-ignored. `compose.yaml` uses `${VAR:-devdefault}` so bare `docker compose up` works on dev defaults while Doppler/.env override. When you add a new env var, add it to `.env.example`, to the relevant service in `compose.yaml`, and read it via `app/core/config.py`. Only local-dev Postgres role passwords stay as fixed non-secret defaults (they guard a local container); real secrets (`API_KEY_PEPPER`, `JWT_SECRET`, prod DB URLs) live only in Doppler.
- **Verify before done**: a change isn't done until the app starts and the touched endpoint responds. Check `docker compose up`, hit the route, and confirm the reload log for code changes.
- **Match the surrounding code**: follow existing naming, async style, and import order rather than introducing new patterns.
- **After a schema change** (new migration): add a test in `db/test_security.sql` proving both the allowed and denied path, run `./db/run_tests.sh`, and regenerate the ERD (`uv run python scripts/gen_erd.py`). Keep diagrams current in the same change.
- **Diagrams**: the ERD is generated — never hand-edit `diagrams/db/riptide-erd.drawio`. The conceptual data model is hand-authored; update it when the model's intent changes.
