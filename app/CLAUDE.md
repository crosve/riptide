# app/ — application code

The FastAPI application lives here. Scope-specific conventions for everything under `app/`.

## Conventions

- **The app instance** is `app` in `app/main.py` (referenced as `app.main:app` by uvicorn). Don't rename it.
- **Async first**: define path operations with `async def`. Only drop to `def` for genuinely blocking, non-awaitable work.
- **Routes**: keep `main.py` thin. Once more than a handful of endpoints exist, split them into routers under `app/routers/` and include them with `app.include_router(...)`. Group by resource, not by HTTP verb.
- **Validation & types**: use Pydantic models for request/response bodies and type-hint every signature. Let FastAPI do validation — don't hand-roll what the framework provides.
- **Keep `/health` dependency-free**: it must stay a cheap liveness check with no external calls.
- **Business logic** belongs in plain modules/functions, not inside route handlers — handlers wire HTTP to logic and return responses.
- **Background work** goes through arq: define the task in `tasks.py` (thin — `async def name(ctx, ...)`), register it in `worker.py`'s `WorkerSettings.functions`, and enqueue from a handler via `request.app.state.redis.enqueue_job("name", ...)`. Keep heavy pipeline logic in `services/`, called by the task.
- **Imports**: absolute imports rooted at `app` (e.g. `from app.routers import ...`).

## When adding structure

Likely next directories as the service grows — create them only when needed:

```
app/
  routers/     # APIRouter modules, one per resource
  models/      # Pydantic schemas
  services/    # business logic / ingestion pipeline code
  core/        # config, settings (pydantic-settings), shared deps
```
