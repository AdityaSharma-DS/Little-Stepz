#!/usr/bin/env bash
# Copies the website database from Neon into ls-postgres (docs/website/DATABASE.md).
#
#   deploy/website/neon-copy.sh rehearse   # site stays live: copies into a scratch database,
#                                          # compares row counts, checks migrations, drops it
#   deploy/website/neon-copy.sh cutover    # little-stepz-backend stopped: copies into the live
#                                          # littlestepz database; row counts must match exactly
#
# Reads Neon's DIRECT connection string (host without "-pooler") from /root/neon.url
# (NEON_URL_FILE). It is passed to the Postgres tools through the environment, never on a
# command line, so it doesn't show up in `ps`. Neon itself is only ever read, never changed.
set -euo pipefail

mode="${1:?usage: neon-copy.sh rehearse|cutover}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
NEON_URL_FILE="${NEON_URL_FILE:-/root/neon.url}"
CONTAINER="${CONTAINER:-ls-postgres}"
DB_USER="${DB_USER:-littlestepz}"
DB_NAME="${DB_NAME:-littlestepz}"
DUMP_DIR="${DUMP_DIR:-/var/backups/website/neon}"
PG_IMAGE="${PG_IMAGE:-$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")}"

case "$mode" in
  rehearse) target="${DB_NAME}_rehearsal" ;;
  cutover) target="$DB_NAME" ;;
  *) echo "usage: neon-copy.sh rehearse|cutover" >&2; exit 1 ;;
esac

[ -f "$NEON_URL_FILE" ] || { echo "Put Neon's direct connection string in $NEON_URL_FILE (chmod 600)" >&2; exit 1; }
NEON_URL="$(tr -d '\r\n' < "$NEON_URL_FILE")"
export NEON_URL
case "$NEON_URL" in
  *-pooler.*) echo "$NEON_URL_FILE holds the pooled URL; use the direct one (host without -pooler)" >&2; exit 1 ;;
esac

# Tools from the same image as ls-postgres, so pg_dump matches the server it restores into.
neon() { docker run --rm -i -e NEON_URL -e PGCONNECT_TIMEOUT=20 -v "$DUMP_DIR:/dump" "$PG_IMAGE" sh -c "$1"; }
neon_sql() { neon "psql \"\$NEON_URL\" -v ON_ERROR_STOP=1 -At -F , $*"; }
local_sql() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$CONTAINER" psql -U "$DB_USER" -d "$1" -v ON_ERROR_STOP=1 -At -F , "${@:2}"; }

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== 1. Versions and size"
neon_major="$(neon_sql -c "'SHOW server_version_num'" | cut -c1-2)"
local_major="$(local_sql postgres -c "SHOW server_version_num" | cut -c1-2)"
echo "Neon: Postgres $neon_major, $(neon_sql -c "'SELECT pg_size_pretty(pg_database_size(current_database()))'")"
echo "ls-postgres: Postgres $local_major"
if [ "$neon_major" -gt "$local_major" ]; then
  echo "Neon runs Postgres $neon_major: change the image in docker/website-postgres.compose.yml to postgres:$neon_major-alpine first" >&2
  exit 1
fi

if [ "$mode" = cutover ]; then
  echo "== 2. Nothing may still write to Neon"
  others="$(neon_sql -c "'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND usename = current_user AND pid <> pg_backend_pid()'")"
  if [ "$others" != 0 ]; then
    neon_sql -c "'SELECT application_name, client_addr, state, backend_start FROM pg_stat_activity WHERE datname = current_database() AND usename = current_user AND pid <> pg_backend_pid()'" >&2
    echo "$others other connection(s) to Neon. Stop little-stepz-backend (pm2 stop little-stepz-backend) and anything else using it, then run again." >&2
    exit 1
  fi
  tables="$(local_sql "$DB_NAME" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
  if [ "$tables" != 0 ]; then
    echo "$DB_NAME on ls-postgres already has $tables tables. Refusing to restore over it." >&2
    exit 1
  fi
fi

echo "== 3. Dump Neon"
dump="neon-$mode-$(date -u +%Y%m%dT%H%M%SZ).dump"
start=$SECONDS
neon "pg_dump \"\$NEON_URL\" --format=custom --compress=9 --no-owner --no-privileges -f /dump/$dump"
(cd "$DUMP_DIR" && chmod 600 "$dump" && sha256sum "$dump" > "$dump.sha256")
echo "Dumped $DUMP_DIR/$dump ($(du -h "$DUMP_DIR/$dump" | cut -f1)) in $((SECONDS - start))s"

echo "== 4. Restore into $target"
start=$SECONDS
if [ "$mode" = rehearse ]; then
  local_sql postgres -c "DROP DATABASE IF EXISTS \"$target\";" > /dev/null
  local_sql postgres -c "CREATE DATABASE \"$target\" OWNER \"$DB_USER\";" > /dev/null
fi
docker exec -i "$CONTAINER" pg_restore -U "$DB_USER" -d "$target" --no-owner --no-privileges --exit-on-error < "$DUMP_DIR/$dump"
echo "Restored in $((SECONDS - start))s"

echo "== 5. Compare row counts"
neon_sql < "$here/table-counts.sql" > "$work/neon.csv"
"$here/table-counts.sh" "$target" > "$work/local.csv"
if diff -u "$work/neon.csv" "$work/local.csv"; then
  echo "MATCH: $(wc -l < "$work/local.csv" | tr -d ' ') tables, $(awk -F, '{ s += $2 } END { print s }' "$work/local.csv") rows"
elif [ "$mode" = cutover ]; then
  echo "MISMATCH: do not switch over. Run: pm2 start little-stepz-backend (it still points at Neon)" >&2
  exit 1
else
  echo "Counts differ (above). Expected only on busy tables while the site is live; orders, products and users must match."
fi

echo "== 6. Prisma sees every migration as applied"
password="$(docker exec "$CONTAINER" printenv POSTGRES_PASSWORD)"
(cd "$root/packages/db" && DATABASE_URL="postgresql://$DB_USER:$password@127.0.0.1:$(docker port "$CONTAINER" 5432 | head -1 | cut -d: -f2)/$target?schema=public" \
  pnpm exec prisma migrate status)

if [ "$mode" = rehearse ]; then
  local_sql postgres -c "DROP DATABASE \"$target\";" > /dev/null
  rm -f "$DUMP_DIR/$dump" "$DUMP_DIR/$dump.sha256"
  echo "Rehearsal done; scratch database and dump removed. Note the dump + restore seconds: that is most of the downtime."
else
  echo "Cutover copy done. Keep $DUMP_DIR/$dump: it is Neon's final state. Next: switch DATABASE_URL (docs/website/DATABASE.md, step 4.4)."
fi
