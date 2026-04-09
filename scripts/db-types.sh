#!/usr/bin/env bash
# Generate TypeScript types from the live Supabase database for THIS project.
# Output:  src/lib/database.types.ts
#
# How it works: SSH to the Supabase server and run a one-shot postgres-meta
# container on the supabase_default docker network. postgres-meta introspects
# the schema and emits typescript to stdout, which we capture locally.
#
# Usage:  ./scripts/db-types.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env.local ]]; then
  echo "ERROR: .env.local not found."
  exit 1
fi

# shellcheck disable=SC1091
source .env.local

: "${SUPABASE_HOST:=root@91.99.87.214}"
: "${SUPABASE_DB_USER:=supabase_admin}"
: "${PG_META_IMAGE:=public.ecr.aws/supabase/postgres-meta:v0.96.1}"
: "${SUPABASE_NETWORK:=supabase_default}"
: "${SUPABASE_DB_HOST:=supabase-db}"
: "${DB_NAME:?Set DB_NAME in .env.local}"
: "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env.local}"

DB_URL="postgresql://${SUPABASE_DB_USER}:${POSTGRES_PASSWORD}@${SUPABASE_DB_HOST}:5432/${DB_NAME}"

mkdir -p src/lib

echo "Generating types from ${DB_NAME}..."
ssh "${SUPABASE_HOST}" \
  "docker run --rm --network ${SUPABASE_NETWORK} \
    -e PG_META_DB_URL='${DB_URL}' \
    -e PG_META_GENERATE_TYPES=typescript \
    ${PG_META_IMAGE} node dist/server/server.js" \
  > src/lib/database.types.ts

if [[ ! -s src/lib/database.types.ts ]]; then
  echo "ERROR: types file is empty — check the error above."
  exit 1
fi

echo "Wrote $(wc -l < src/lib/database.types.ts) lines to src/lib/database.types.ts"
