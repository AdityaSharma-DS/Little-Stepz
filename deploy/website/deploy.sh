#!/usr/bin/env bash
# Deploys the website (web + backend) on the VPS from /var/www/little-stepz:
# backup → pull → install → migrate → build → reload → health check.
#
#   deploy/website/deploy.sh [git-ref]        # default: the current branch
#
# Stops at the first failure. Migrations only ever run after a fresh backup, so a bad
# release can be rolled back with restore.sh (docs/website/DATABASE.md). Builds only the
# website's apps; the CRM deploys from its own checkout (deploy/crm/deploy.sh).
# PM2 reads ecosystem.config.js in the repo root (created on the server, not in git).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
ref="${1:-$(git rev-parse --abbrev-ref HEAD)}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
WEB_PORT="${WEB_PORT:-3000}"

[ -f ecosystem.config.js ] || { echo "No ecosystem.config.js in $root" >&2; exit 1; }

echo "== Backup before deploying"
if grep -qsE '^DATABASE_URL=.*neon\.tech' packages/db/.env apps/backend/.env; then
  echo "DATABASE_URL still points at Neon: skipping the local backup (Neon keeps its own history)"
else
  "$root/deploy/website/backup.sh"
fi

echo "== Fetch $ref"
git fetch --prune origin
git checkout "$ref"
git pull --ff-only origin "$ref"
echo "Deploying $(git rev-parse --short HEAD)"

echo "== Install"
pnpm install --frozen-lockfile

echo "== Prisma client and migrations"
pnpm --filter @repo/db exec prisma generate
pnpm --filter @repo/db exec prisma migrate deploy

echo "== Build web and backend"
pnpm exec turbo run build --filter=web --filter=backend

echo "== Reload"
pm2 reload ecosystem.config.js --update-env
pm2 save

echo "== Health"
for i in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:$BACKEND_PORT/health" > /dev/null 2>&1 && curl -fsS -o /dev/null "http://127.0.0.1:$WEB_PORT/" 2> /dev/null; then
    echo "Healthy: $(git rev-parse --short HEAD) is live"
    exit 0
  fi
  sleep 3
done
echo "Health check failed; see: pm2 logs little-stepz-backend --lines 100" >&2
exit 1
