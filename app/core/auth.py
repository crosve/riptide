"""Authentication (step 1) and per-request DB context (step 2).

A single FastAPI dependency, ``request_context``, does both:
  1. authenticate the caller (API key or session JWT) -> Principal
  2. open a transaction on a riptide_api connection and SET LOCAL
     app.tenant_id / app.user_id, so every query the endpoint runs is
     automatically confined by RLS to that tenant and user.
"""

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import asyncpg
import jwt
from fastapi import Header, HTTPException, status

from app.core import db, security
from app.core.config import JWT_ALGORITHM, JWT_SECRET


@dataclass
class Principal:
    tenant_id: uuid.UUID
    user_id: uuid.UUID
    auth_method: str
    scopes: list[str] = field(default_factory=list)
    collection_id: uuid.UUID | None = None


@dataclass
class RequestContext:
    """Everything an endpoint needs: a tenant-scoped connection + who is calling."""

    conn: asyncpg.Connection
    principal: Principal


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def mint_session_token(
    tenant_id: uuid.UUID | str,
    user_id: uuid.UUID | str,
    scopes: list[str] | None = None,
    ttl_seconds: int = 3600,
) -> str:
    """Issue an HS256 session token. (OIDC will replace this later.)"""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "tenant_id": str(tenant_id),
        "scopes": scopes or [],
        "iat": now,
        "exp": now + timedelta(seconds=ttl_seconds),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


async def _authenticate_api_key(conn: asyncpg.Connection, full_key: str) -> Principal:
    parsed = security.parse_api_key(full_key)
    if parsed is None:
        raise _unauthorized("malformed API key")
    prefix, secret = parsed

    # SECURITY DEFINER lookup: works before any tenant context is established.
    row = await conn.fetchrow("SELECT * FROM app_authenticate_api_key($1)", prefix)
    if row is None or not security.verify_secret(secret, row["key_hash"]):
        raise _unauthorized("invalid API key")

    now = datetime.now(timezone.utc)
    if row["revoked_at"] is not None:
        raise _unauthorized("API key revoked")
    if row["expires_at"] is not None and row["expires_at"] <= now:
        raise _unauthorized("API key expired")

    await conn.execute("SELECT app_touch_api_key($1)", row["id"])
    return Principal(
        tenant_id=row["tenant_id"],
        user_id=row["acts_as_user"],
        auth_method="api_key",
        scopes=list(row["scopes"] or []),
        collection_id=row["collection_id"],
    )


def _authenticate_jwt(token: str) -> Principal:
    try:
        claims = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return Principal(
            tenant_id=uuid.UUID(claims["tenant_id"]),
            user_id=uuid.UUID(claims["sub"]),
            auth_method="jwt",
            scopes=list(claims.get("scopes", [])),
        )
    except jwt.PyJWTError as exc:
        raise _unauthorized(f"invalid token: {exc}")
    except (KeyError, ValueError):
        raise _unauthorized("token missing tenant_id/sub")


async def request_context(
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None),
):
    """FastAPI dependency: authenticated, tenant-scoped DB context per request."""
    async with db.pool().acquire() as conn:
        # --- step 1: authenticate (before any tenant context) ---------------
        if x_api_key:
            principal = await _authenticate_api_key(conn, x_api_key)
        elif authorization:
            scheme, _, credential = authorization.partition(" ")
            scheme = scheme.lower()
            if scheme == "bearer":
                principal = _authenticate_jwt(credential)
            elif scheme == "apikey":
                principal = await _authenticate_api_key(conn, credential)
            else:
                raise _unauthorized("unsupported authorization scheme")
        else:
            raise _unauthorized("missing credentials")

        # --- step 2: tenant-scoped transaction (SET LOCAL, fail closed) -----
        tx = conn.transaction()
        await tx.start()
        try:
            await conn.execute("SELECT set_config('app.tenant_id', $1, true)", str(principal.tenant_id))
            await conn.execute("SELECT set_config('app.user_id', $1, true)", str(principal.user_id))
            yield RequestContext(conn=conn, principal=principal)
        except Exception:
            await tx.rollback()
            raise
        else:
            await tx.commit()
