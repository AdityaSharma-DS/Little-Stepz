#!/usr/bin/env bash
# Restores a backup made by backup.sh into a database, then prints row counts.
#
#   deploy/website/restore.sh <file.dump> [target-db]
#
# The target defaults to a scratch database (littlestepz_restore), so a restore
# never touches live data by accident. Restoring over the live database needs
# CONFIRM_LIVE_RESTORE=yes, and the backend must be stopped first
# (pm2 stop little-stepz-backend); see docs/website/DATABASE.md.
set -euo pipefail

dump="${1:?usage: restore.sh <file.dump> [target-db]}"
CONTAINER="${CONTAINER:-ls-postgres}"
DB_USER="${DB_USER:-littlestepz}"
DB_NAME="${DB_NAME:-littlestepz}"
target="${2:-${DB_NAME}_restore}"

[ -f "$dump" ] || { echo "No such file: $dump" >&2; exit 1; }

if [ -f "$dump.sha256" ]; then
  (cd "$(dirname "$dump")" && sha256sum --check --quiet "$(basename "$dump").sha256")
  echo "Checksum OK"
else
  echo "WARNING: no checksum file next to the dump" >&2
fi

if [ "$target" = "$DB_NAME" ] && [ "${CONFIRM_LIVE_RESTORE:-}" != "yes" ]; then
  echo "Refusing to overwrite the live database $DB_NAME. Set CONFIRM_LIVE_RESTORE=yes after stopping little-stepz-backend." >&2
  exit 1
fi

psql_in() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$CONTAINER" psql -U "$DB_USER" -d "$1" -v ON_ERROR_STOP=1 -At "${@:2}"; }

psql_in postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$target' AND pid <> pg_backend_pid();" > /dev/null
psql_in postgres -c "DROP DATABASE IF EXISTS \"$target\";" > /dev/null
psql_in postgres -c "CREATE DATABASE \"$target\" OWNER \"$DB_USER\";" > /dev/null
docker exec -i "$CONTAINER" pg_restore -U "$DB_USER" -d "$target" --no-owner --no-privileges --exit-on-error < "$dump"

echo "Restored $(basename "$dump") into $target"
"$(dirname "$0")/table-counts.sh" "$target"
