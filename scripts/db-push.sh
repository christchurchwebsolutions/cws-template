#!/usr/bin/env bash
# Apply pending Supabase migrations to the live database.
#
# Each migration in supabase/migrations/*.sql is applied in filename order.
# Applied migrations are tracked in a table called `_cws_migrations` inside
# the project's schema within the `postgres` database.
#
# Usage:  ./scripts/db-push.sh
# Reads:  .env.local  (DB_SCHEMA, SUPABASE_HOST)

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env.local ]]; then
  echo "ERROR: .env.local not found. Copy .env.example -> .env.local and fill it in."
  exit 1
fi

# shellcheck disable=SC1091
source .env.local

: "${SUPABASE_HOST:=root@91.99.87.214}"
: "${SUPABASE_DB_USER:=supabase_admin}"
: "${SUPABASE_DB_CONTAINER:=supabase-db}"
: "${DB_SCHEMA:?Set DB_SCHEMA in .env.local (e.g. DB_SCHEMA=cortex)}"

PSQL_CMD="docker exec -i ${SUPABASE_DB_CONTAINER} psql -U ${SUPABASE_DB_USER} -d postgres -v ON_ERROR_STOP=1"

# 1. Ensure the project schema exists.
echo "Ensuring schema '${DB_SCHEMA}' exists in postgres..."
ssh "${SUPABASE_HOST}" "${PSQL_CMD} -c \"CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};\"" >/dev/null

# 2. Ensure migration tracking table exists in the project schema.
echo "Ensuring ${DB_SCHEMA}._cws_migrations table exists..."
ssh "${SUPABASE_HOST}" "${PSQL_CMD} -c \"CREATE TABLE IF NOT EXISTS ${DB_SCHEMA}._cws_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now());\"" >/dev/null

# 3. Get list of already-applied migrations.
APPLIED=$(ssh "${SUPABASE_HOST}" "${PSQL_CMD} -At -c \"SELECT name FROM ${DB_SCHEMA}._cws_migrations ORDER BY name;\"")

# 4. Walk migrations in order, apply any that are missing.
shopt -s nullglob
APPLIED_COUNT=0
for f in supabase/migrations/*.sql; do
  base=$(basename "$f")
  if grep -qx "$base" <<<"$APPLIED"; then
    echo "  - already applied:  $base"
    continue
  fi
  echo "  + applying:         $base"
  ssh "${SUPABASE_HOST}" "${PSQL_CMD}" < "$f"
  ssh "${SUPABASE_HOST}" "${PSQL_CMD} -c \"INSERT INTO ${DB_SCHEMA}._cws_migrations (name) VALUES ('$base');\"" >/dev/null
  APPLIED_COUNT=$((APPLIED_COUNT + 1))
done

echo "Done. ${APPLIED_COUNT} new migration(s) applied to schema '${DB_SCHEMA}'."
