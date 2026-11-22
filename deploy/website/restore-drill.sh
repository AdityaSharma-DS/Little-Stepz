#!/usr/bin/env bash
# Proves the backups work: takes a fresh backup, restores it into a scratch
# database, and checks every table has the same number of rows as the live one.
# The scratch database is dropped afterwards. Run monthly (deploy/website/crontab.txt)
# and after any change to the backup set-up. Exits non-zero on any mismatch.
#
#   deploy/website/restore-drill.sh
#
# Run it in a quiet hour: counts on busy tables (refresh tokens, carts) may differ
# by what was written during the drill.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="${CONTAINER:-ls-postgres}"
DB_USER="${DB_USER:-littlestepz}"
DB_NAME="${DB_NAME:-littlestepz}"
scratch="${DB_NAME}_drill"
work="$(mktemp -d)"
trap 'rm -rf "$work"; docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -qc "DROP DATABASE IF EXISTS \"$scratch\";" > /dev/null 2>&1 || true' EXIT

echo "== 1. Backup"
BACKUP_DIR="$work" OFFSITE="" RETAIN_DAYS=1 "$here/backup.sh" 2> >(grep -v 'OFFSITE is not set' >&2)
dump="$(ls "$work"/website-*.dump)"

echo "== 2. Restore into $scratch"
"$here/restore.sh" "$dump" "$scratch" > "$work/restored.txt"
sed -n '1,2p' "$work/restored.txt"

echo "== 3. Compare row counts"
"$here/table-counts.sh" "$DB_NAME" > "$work/live.csv"
"$here/table-counts.sh" "$scratch" > "$work/copy.csv"
tables="$(wc -l < "$work/live.csv" | tr -d ' ')"
rows="$(awk -F, '{ s += $2 } END { print s }' "$work/live.csv")"
if diff -u "$work/live.csv" "$work/copy.csv"; then
  echo "PASS: $tables tables and $rows rows match between $DB_NAME and the restored copy"
else
  echo "FAIL: the restored copy differs from $DB_NAME (see above)" >&2
  exit 1
fi

echo "== 4. Spot checks on the restored copy"
docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$scratch" -v ON_ERROR_STOP=1 -At <<'SQL'
SELECT 'migrations applied: ' || count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL;
SELECT 'newest order: ' || COALESCE(max("createdAt")::text, 'none') FROM "Order";
SQL
