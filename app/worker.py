"""arq worker entrypoint.

Run with:  arq app.worker.WorkerSettings
In dev the compose worker service adds --watch for hot reload.
"""

from arq.connections import RedisSettings

from app.core.config import REDIS_URL
from app.tasks import ingest


async def startup(ctx) -> None:
    pass


async def shutdown(ctx) -> None:
    pass


class WorkerSettings:
    functions = [ingest]
    redis_settings = RedisSettings.from_dsn(REDIS_URL)
    on_startup = startup
    on_shutdown = shutdown
