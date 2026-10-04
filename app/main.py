from contextlib import asynccontextmanager

from arq import create_pool
from arq.connections import RedisSettings
from fastapi import Depends, FastAPI, Request
from pydantic import BaseModel

from app.core import db
from app.core.auth import Principal, RequestContext, mint_session_token, request_context
from app.core.config import DEV_AUTH, REDIS_URL


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Redis pool for enqueuing jobs, and the RLS-enforced Postgres pool.
    app.state.redis = await create_pool(RedisSettings.from_dsn(REDIS_URL))
    await db.connect()
    yield
    await db.disconnect()
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


# --- Authenticated endpoints (tenant-scoped via RLS) ------------------------

@app.get("/me")
async def me(ctx: RequestContext = Depends(request_context)):
    """Resolve the caller inside their own tenant context (proves RLS works)."""
    row = await ctx.conn.fetchrow(
        "SELECT email, clearance_level, is_tenant_admin FROM users WHERE id = app_current_user_id()"
    )
    p: Principal = ctx.principal
    return {
        "tenant_id": str(p.tenant_id),
        "user_id": str(p.user_id),
        "auth_method": p.auth_method,
        "scopes": p.scopes,
        "email": row["email"] if row else None,
        "clearance_level": row["clearance_level"] if row else None,
        "is_tenant_admin": row["is_tenant_admin"] if row else None,
    }


@app.get("/documents")
async def list_documents(ctx: RequestContext = Depends(request_context)):
    """List documents the caller may see. RLS does the permission filtering."""
    rows = await ctx.conn.fetch(
        "SELECT id, title, classification FROM documents ORDER BY created_at"
    )
    return {
        "documents": [
            {"id": str(r["id"]), "title": r["title"], "classification": r["classification"]}
            for r in rows
        ]
    }


if DEV_AUTH:
    class DevTokenRequest(BaseModel):
        tenant_id: str
        user_id: str
        scopes: list[str] = []

    @app.post("/auth/dev-token")
    async def dev_token(req: DevTokenRequest):
        """DEV ONLY: mint a session JWT for a (tenant_id, user_id)."""
        return {"token": mint_session_token(req.tenant_id, req.user_id, req.scopes)}
