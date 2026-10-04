#!/usr/bin/env bash
# Rebuild a throwaway database and run the security test suite.
#
#   PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres ./db/run_tests.sh
#
# Requires pgvector (use the pgvector/pgvector:pg16 image). The schema is built by
# running the Alembic migrations as the non-superuser owner (riptide_owner), so
# FORCE RLS is exercised exactly as in production; tests run as riptide_api /
# riptide_worker. This tests the real migration path, not a separate schema file.
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
OWNER_PW="${RIPTIDE_OWNER_PW:-owner_pw}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
TESTDB="riptide_test_$$"
ADMINDB="${PGADMINDB:-postgres}"

psql_admin() { psql -v ON_ERROR_STOP=1 -X -q -d "$ADMINDB" "$@"; }
psql_test()  { psql -v ON_ERROR_STOP=1 -X -q -d "$TESTDB"  "$@"; }

cleanup() {
    psql_admin -c "DROP DATABASE IF EXISTS \"$TESTDB\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> creating throwaway database $TESTDB"
psql_admin -c "CREATE DATABASE \"$TESTDB\""

echo "==> bootstrap (roles + extensions)"
psql_test -f "$DIR/bootstrap.sql" >/dev/null

echo "==> applying migrations (alembic upgrade head, as riptide_owner)"
MIGRATION_DATABASE_URL="postgresql+psycopg://riptide_owner:${OWNER_PW}@${PGHOST}:${PGPORT}/${TESTDB}" \
    uv run --project "$ROOT" alembic -c "$ROOT/alembic.ini" upgrade head

echo "==> running tests"
psql_test -f "$DIR/test_security.sql"

echo "==> done"
