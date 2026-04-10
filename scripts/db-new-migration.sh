#!/usr/bin/env bash
# Create a new timestamped migration file in supabase/migrations/.
# The migration template sets search_path to the project schema so
# all CREATE TABLE etc. land in the right place.
#
# Usage:  ./scripts/db-new-migration.sh "create contact submissions table"

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"short description with underscores or spaces\""
  exit 1
fi

if [[ ! -f .env.local ]]; then
  echo "ERROR: .env.local not found. Need DB_SCHEMA."
  exit 1
fi

# shellcheck disable=SC1091
source .env.local
: "${DB_SCHEMA:?Set DB_SCHEMA in .env.local}"

NAME=$(echo "$1" | tr ' ' '_' | tr -cd '[:alnum:]_')
TIMESTAMP=$(date -u +%Y%m%d%H%M%S)
FILE="supabase/migrations/${TIMESTAMP}_${NAME}.sql"

mkdir -p supabase/migrations
cat > "${FILE}" <<EOF
-- Migration: ${NAME}
-- Created: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
-- Schema: ${DB_SCHEMA}

SET search_path TO ${DB_SCHEMA}, public;

EOF

echo "Created ${FILE}"
