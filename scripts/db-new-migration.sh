#!/usr/bin/env bash
# Create a new timestamped migration file in supabase/migrations/.
#
# Usage:  ./scripts/db-new-migration.sh "create contact submissions table"

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"short description with underscores or spaces\""
  exit 1
fi

NAME=$(echo "$1" | tr ' ' '_' | tr -cd '[:alnum:]_')
TIMESTAMP=$(date -u +%Y%m%d%H%M%S)
FILE="supabase/migrations/${TIMESTAMP}_${NAME}.sql"

mkdir -p supabase/migrations
cat > "${FILE}" <<EOF
-- Migration: ${NAME}
-- Created: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

EOF

echo "Created ${FILE}"
