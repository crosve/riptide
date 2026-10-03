# riptide

FastAPI service managed with [uv](https://docs.astral.sh/uv/) and run via Docker with hot reload.

## Layout

```
app/
  __init__.py
  main.py          # FastAPI app + routes
Dockerfile         # uv-based image, runs uvicorn --reload
compose.yaml       # bind-mounts ./app for live reload
pyproject.toml     # dependencies
uv.lock            # locked versions
```

## Run with Docker (recommended)

```bash
docker compose up --build
```

The API is at http://localhost:8000 (`/` and `/health`). Docs at http://localhost:8000/docs.

`./app` is bind-mounted into the container and uvicorn runs with `--reload`, so
saving any file under `app/` reloads the server automatically — no restart needed.

Stop with `Ctrl-C`, or `docker compose down` if running detached (`-d`).

> Note: hot reload covers **code** changes. If you change dependencies
> (`pyproject.toml`), rebuild: `docker compose up --build`.

## Run locally without Docker

```bash
uv sync
uv run fastapi dev app/main.py
```

## Add a dependency

```bash
uv add <package>
```
# riptide
