"""arq task functions.

Each task receives the arq context `ctx` as its first argument. Keep these thin:
they wire the queue to real work that lives in `app/services/`.
"""

import asyncio


async def ingest(ctx, source: str) -> dict:
    """Sample ingestion job. Replace the body with real pipeline work."""
    # Simulate some async I/O (fetch, parse, store, ...).
    await asyncio.sleep(1)
    return {"source": source, "status": "ingested"}
