import os

# Redis connection string. Overridden in Docker via compose (service name "redis");
# falls back to localhost for non-Docker local runs.
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")

# Request-path DB connection. This MUST be a login role that is a member of
# riptide_api (never the owner or a superuser) so RLS is enforced.
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://riptide_api_login:api_pw@localhost:5432/riptide",
)

# Migration path. Alembic connects as the schema owner (NOT an app role) using a
# sync driver (psycopg). Keep this out of the request path.
MIGRATION_DATABASE_URL = os.getenv(
    "MIGRATION_DATABASE_URL",
    "postgresql+psycopg://riptide_owner:owner_pw@localhost:5432/riptide",
)

# Server-side secret mixed into API-key hashes (HMAC pepper). Rotate in prod.
API_KEY_PEPPER = os.getenv("API_KEY_PEPPER", "dev-pepper-change-me")

# Session/JWT signing (OIDC comes later; HS256 session tokens for now).
JWT_SECRET = os.getenv("JWT_SECRET", "dev-jwt-secret-change-me")
JWT_ALGORITHM = "HS256"

# Guards the dev-only token-minting endpoint. Never enable in production.
DEV_AUTH = os.getenv("RIPTIDE_DEV_AUTH", "0") == "1"
