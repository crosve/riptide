from contextlib import asynccontextmanager

from arq import create_pool
from arq.connections import RedisSettings
from fastapi import FastAPI, Request
from pydantic import BaseModel

from app.core.config import REDIS_URL


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Shared Redis pool for enqueuing jobs onto the arq queue.
    app.state.redis = await create_pool(RedisSettings.from_dsn(REDIS_URL))
    yield
    await app.state.redis.aclose()


app = FastAPI(title="riptide", lifespan=lifespan)


class IngestRequest(BaseModel):
    source: str


@app.get("/")
async def root():
    return {"message": "riptide is running"}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/ingest")
async def ingest(req: IngestRequest, request: Request):
    """Enqueue an ingestion job and return its id."""
    job = await request.app.state.redis.enqueue_job("ingest", req.source)
    return {"job_id": job.job_id, "source": req.source}
