#!/usr/bin/env bash
# Backup of the website database: a compressed pg_dump, checked readable,
# checksummed, copied off the server, and old local copies pruned.
#
#   deploy/website/backup.sh                  # cron: see deploy/website/crontab.txt
#
# Settings (environment, or /etc/website-backup.env which is read if present):
#   OFFSITE       rclone destination, e.g. "r2:littlestepz-backups/website". Empty = local only (warns).
#   BACKUP_DIR    local folder (default /var/backups/website)
#   RETAIN_DAYS   local copies kept (default 14); off-server retention is a lifecycle rule on the bucket
#   CONTAINER / DB_USER / DB_NAME   the ls-postgres container and database
set -euo pipefail

[ -f /etc/website-backup.env ] && . /etc/website-backup.env

BACKUP_DIR="${BACKUP_DIR:-/var/backups/website}"
RETAIN_DAYS="${RETAIN_DAYS:-14}"
CONTAINER="${CONTAINER:-ls-postgres}"
DB_USER="${DB_USER:-littlestepz}"
DB_NAME="${DB_NAME:-littlestepz}"
OFFSITE="${OFFSITE:-}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
file="$BACKUP_DIR/website-$stamp.dump"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=custom --compress=9 --no-owner --no-privileges > "$file.partial"

# A dump pg_restore can't read is not a backup: fail loudly instead of keeping it.
docker exec -i "$CONTAINER" pg_restore --list < "$file.partial" > /dev/null
mv "$file.partial" "$file"
(cd "$BACKUP_DIR" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256")

if [ -n "$OFFSITE" ]; then
  rclone copy "$file" "$OFFSITE/"
  rclone copy "$file.sha256" "$OFFSITE/"
  echo "Copied off-server to $OFFSITE"
else
  echo "WARNING: OFFSITE is not set; this backup exists on this server only" >&2
fi

find "$BACKUP_DIR" -maxdepth 1 -name 'website-*.dump*' -mtime +"$RETAIN_DAYS" -delete

echo "Backup written: $file ($(du -h "$file" | cut -f1))"
