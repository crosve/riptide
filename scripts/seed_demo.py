"""Provision a demo tenant and print credentials to exercise the auth layer.

Connects as a superuser (provisioning path — NOT the request path) to create a
tenant, two users, a collection with a grant, and a couple of documents, then
registers an API key and prints the full key + session JWTs.

    uv run python scripts/seed_demo.py
"""

import asyncio
import os
import uuid

import asyncpg

from app.core import security
from app.core.auth import mint_session_token

# Provisioning uses a superuser DSN; the app itself never does.
SEED_DSN = os.getenv("SEED_DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/riptide")

TENANT = uuid.UUID("d0000000-0000-0000-0000-000000000001")
ADMIN = uuid.UUID("d0000000-0000-0000-0000-00000000a001")
READER = uuid.UUID("d0000000-0000-0000-0000-00000000a002")
COLLECTION = uuid.UUID("d0000000-0000-0000-0000-0000000c0001")
DOC_PUBLIC = uuid.UUID("d0000000-0000-0000-0000-0000000d0001")
DOC_SECRET = uuid.UUID("d0000000-0000-0000-0000-0000000d0002")


async def main() -> None:
    conn = await asyncpg.connect(SEED_DSN)
    try:
        # Clean slate (cascades to everything in the tenant).
        await conn.execute("DELETE FROM tenants WHERE id = $1", TENANT)

        await conn.execute("INSERT INTO tenants (id, name) VALUES ($1, 'Demo Co')", TENANT)
        await conn.execute(
            "INSERT INTO users (id, tenant_id, email, clearance_level, is_tenant_admin) VALUES "
            "($1,$3,'admin@demo.test',3,true), ($2,$3,'reader@demo.test',1,false)",
            ADMIN, READER, TENANT,
        )
        await conn.execute(
            "INSERT INTO collections (id, tenant_id, name) VALUES ($1,$2,'Handbook')",
            COLLECTION, TENANT,
        )
        await conn.execute(
            "INSERT INTO collection_grants (tenant_id, collection_id, user_id, role) VALUES ($1,$2,$3,'viewer')",
            TENANT, COLLECTION, READER,
        )
        await conn.execute(
            "INSERT INTO documents (id, tenant_id, collection_id, title, classification) VALUES "
            "($1,$3,$4,'Employee Handbook',0), ($2,$3,$4,'Board Minutes (Confidential)',2)",
            DOC_PUBLIC, DOC_SECRET, TENANT, COLLECTION,
        )

        full_key, prefix, key_hash = security.generate_api_key()
        await conn.execute(
            "INSERT INTO api_keys (tenant_id, acts_as_user, key_prefix, key_hash) VALUES ($1,$2,$3,$4)",
            TENANT, READER, prefix, key_hash,
        )
    finally:
        await conn.close()

    print("Demo tenant provisioned.\n")
    print(f"  tenant_id : {TENANT}")
    print(f"  admin     : {ADMIN}  (clearance 3, tenant admin)")
    print(f"  reader    : {READER}  (clearance 1, viewer on Handbook)\n")
    print("API key (acts as reader, shown once):")
    print(f"  {full_key}\n")
    print("Session JWTs:")
    print(f"  admin : {mint_session_token(TENANT, ADMIN)}")
    print(f"  reader: {mint_session_token(TENANT, READER)}")


if __name__ == "__main__":
    asyncio.run(main())
