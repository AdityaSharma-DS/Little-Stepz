#!/usr/bin/env bash
# Exact row count of every table in a website database, one "table,rows" line each.
#
#   deploy/website/table-counts.sh [database]
set -euo pipefail

CONTAINER="${CONTAINER:-ls-postgres}"
DB_USER="${DB_USER:-littlestepz}"
db="${1:-${DB_NAME:-littlestepz}}"

docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$db" -v ON_ERROR_STOP=1 -At -F , < "$(dirname "$0")/table-counts.sql"
