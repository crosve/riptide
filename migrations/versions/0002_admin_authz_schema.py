"""admin authorization: gated write RLS for the request path

Step 3 of the security layer. Adds INSERT/UPDATE/DELETE policies + (column-scoped)
grants so riptide_api can perform admin actions only for the right principal, and
hardens app_collection_role to be tenant-aware. SQL lives in the sibling .sql files.

Revision ID: 0002_admin_authz
Revises: 0001_initial
Create Date: 2026-10-05
"""
from pathlib import Path
from typing import Sequence, Union

from alembic import op

revision: str = "0002_admin_authz"
down_revision: Union[str, None] = "0001_initial"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_HERE = Path(__file__).parent


def _sql(name: str) -> str:
    return (_HERE / name).read_text()


def upgrade() -> None:
    op.execute(_sql("0002_admin_authz_up.sql"))


def downgrade() -> None:
    op.execute(_sql("0002_admin_authz_down.sql"))
