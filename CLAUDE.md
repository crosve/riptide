# riptide

FastAPI service. This file orients any contributor (human or AI) to the platform and the practices we hold to.

## Platform / stack

- **Language**: Python 3.12 (pinned in `.python-version`; `requires-python = ">=3.12"`).
- **Framework**: FastAPI with the `[standard]` extras (uvicorn, websockets, the `fastapi` CLI).
- **Package manager**: **uv** — the only supported one. Do not use `pip`, `poetry`, `pipenv`, or hand-edit `uv.lock`.
- **Runtime**: Docker via `docker compose`. Local non-Docker runs are supported for quick checks but Docker is the source of truth.
- **ASGI server**: uvicorn, run with `--reload` in development.
- **Queue**: **arq** (async, Redis-backed) for background jobs / the ingestion pipeline. Redis runs as a compose service; a `worker` service runs `arq app.worker.WorkerSettings`.

## Layout

```
app/
  __init__.py
  main.py          # FastAPI app instance + routes (see app/CLAUDE.md)
  worker.py        # arq WorkerSettings entrypoint
  tasks.py         # arq task functions (thin; call into services/)
  core/config.py   # env-driven settings (REDIS_URL)
Dockerfile         # uv-based image (shared by api + worker)
compose.yaml       # dev runtime: api, worker, redis — bind-mounts ./app for hot reload
diagrams/          # draw.io diagrams, mirrors the app/ module layout (see diagrams/README.md)
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

The API serves on `http://localhost:8000`; interactive docs at `/docs`.

## Clean practices

- **Dependencies**: add/remove only through `uv add` / `uv remove` so `pyproject.toml` and `uv.lock` stay in sync. Commit both. After changing dependencies, rebuild the image (`docker compose up --build`) — hot reload only covers code.
- **Keep it lean**: this is a base. Don't add dependencies, config, or abstractions until a concrete need exists. Prefer the standard library and FastAPI built-ins first.
- **Routes & structure**: see `app/CLAUDE.md` for code-level conventions.
- **No secrets in the repo**: configuration comes from environment variables (set in `compose.yaml` or a local `.env`, which must stay git-ignored). Never commit credentials.
- **Verify before done**: a change isn't done until the app starts and the touched endpoint responds. Check `docker compose up`, hit the route, and confirm the reload log for code changes.
- **Match the surrounding code**: follow existing naming, async style, and import order rather than introducing new patterns.
