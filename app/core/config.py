import os

# Redis connection string. Overridden in Docker via compose (service name "redis");
# falls back to localhost for non-Docker local runs.
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
