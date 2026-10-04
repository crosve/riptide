"""Async Postgres pool for the request path.

The pool connects as a login role that is a member of riptide_api, so every
statement is subject to row-level security. Per-request tenant/user context is
set with SET LOCAL inside a transaction (see app.core.auth.request_context),
never SET, so values can never leak across pooled connections.
"""

import asyncpg

from app.core.config import DATABASE_URL

_pool: asyncpg.Pool | None = None


async def connect() -> None:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(dsn=DATABASE_URL, min_size=1, max_size=10)


async def disconnect() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("database pool is not initialized")
    return _pool
