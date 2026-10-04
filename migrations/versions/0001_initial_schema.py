"""initial schema: tables, composite FKs, RLS, triggers, functions

Baseline migration. The SQL is kept in sibling .sql files (0001_initial_up.sql /
0001_initial_down.sql) so it stays readable and reviewable rather than buried in
a Python string. Prerequisite: db/bootstrap.sql has created the extensions
(vector, pgcrypto) and roles; this migration runs as riptide_owner.

Revision ID: 0001_initial
Revises:
Create Date: 2026-10-04
"""
from pathlib import Path
from typing import Sequence, Union

from alembic import op

revision: str = "0001_initial"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_HERE = Path(__file__).parent


def _sql(name: str) -> str:
    return (_HERE / name).read_text()


def upgrade() -> None:
    op.execute(_sql("0001_initial_up.sql"))


def downgrade() -> None:
    op.execute(_sql("0001_initial_down.sql"))
