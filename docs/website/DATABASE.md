# Website database on the VPS (moving off Neon)

The website's Postgres moves from Neon into a Docker container, `ls-postgres`, on the same VPS that runs the
backend. It sits next to the CRM's `crm-postgres`; each has its own container, data volume, backups and restore
drill. Neon is only ever read during the move and stays untouched until it is retired, so it is the rollback.

| | Website | CRM (unchanged) |
| --- | --- | --- |
| Container | `ls-postgres`, Postgres 17 | `crm-postgres`, Postgres 17 |
| Listens on | 127.0.0.1:5432 | 127.0.0.1:5433 |
| Compose file | `docker/website-postgres.compose.yml` | `docker/crm-postgres.compose.yml` |
| Run from | /var/www/little-stepz | /srv/littlestepz |
| Scripts | `deploy/website/` | `deploy/crm/` |
| Local backups | /var/backups/website (14 days) | /var/backups/crm (14 days) |
| Off-server | `r2:littlestepz-backups/website` (30 days) | `r2:littlestepz-backups/crm` (30 days) |
| Backup settings | /etc/website-backup.env | /etc/crm-backup.env |
| Nightly backup | 21:15 UTC (02:45 IST) | 20:45 UTC (02:15 IST) |

Commands run on the VPS as root unless marked *(laptop)*. Never paste a password or connection string into a
chat, ticket or this file; they live only in the root-only files named below.

Never run `docker compose down -v` or `docker volume prune`: either deletes the database.

---

## Phase 0 — Collect facts (no downtime)

```sh
ssh root@187.77.187.253
cd /var/www/little-stepz && git status -sb && git log --oneline -1

pm2 list                                            # backend/frontend names and mode
free -h; df -h /                                    # ~1 GB RAM free for Postgres, a few GB of disk
ss -tlnp | grep ':5432\b'                           # must print nothing (port free)

# Every place the Neon URL lives (the backend reads packages/db/.env through Prisma, or
# apps/backend/.env through dotenv; PM2 may also hold a copy in its saved environment)
grep -rln 'neon\.tech' /var/www/little-stepz --include='.env*' 2>/dev/null
pm2 jlist | grep -o 'neon\.tech' | wc -l            # 0 = PM2 holds no copy of the URL
grep -ls 'neon\.tech' /etc/environment ~/.bashrc ~/.profile /var/www/little-stepz/ecosystem.config.js
```

Write down every file the `grep`s print. Each one changes at cutover. If the `pm2 jlist` line prints more than
`0`, PM2 keeps its own copy of the URL; tell whoever is helping before the cutover, because a plain restart would
keep using Neon.

## Phase 1 — Start `ls-postgres` (no downtime)

### 1.1 Get the new scripts into the website folder

The scripts arrive with the commit that added this file. Pull it the usual way (the site keeps running; nothing
is rebuilt yet):

```sh
cd /var/www/little-stepz && git pull --ff-only origin main
ls deploy/website                     # backup.sh deploy.sh neon-copy.sh restore.sh …
```

### 1.2 Database password and container

Run in one session, top to bottom. The password is hex, so it needs no escaping inside a URL.

```sh
cd /var/www/little-stepz
LSPW=$(openssl rand -hex 24)
cp docker/.env.sample docker/.env
sed -i "s/^LS_DB_PASSWORD=.*/LS_DB_PASSWORD=$LSPW/" docker/.env
sed -i '/^CRM_DB_/d' docker/.env          # the CRM's values live in /srv/littlestepz/docker/.env only
chmod 600 docker/.env

docker compose -f docker/website-postgres.compose.yml --env-file docker/.env up -d
sleep 15; docker ps --filter name=ls-postgres      # STATUS shows (healthy)
ss -tlnp | grep ':5432\b'                          # must start with 127.0.0.1:5432, NOT 0.0.0.0
```

Save the password from `docker/.env` in the password manager. The container has `restart: unless-stopped`, so it
comes back by itself after a reboot.

### 1.3 Neon's direct connection string

In the Neon console → **Connect**, turn **Connection pooling off** and copy the string. Its host has no
`-pooler`; dumps over the pooler can fail. Paste it into a root-only file, never into a chat:

```sh
install -m 600 /dev/null /root/neon.url
nano /root/neon.url                   # paste the DIRECT string on one line, save
```

## Phase 2 — Off-server backups with Cloudflare R2 (no downtime)

One bucket holds both databases' backups, so this also finishes the CRM's missing off-server copy.

### 2.1 In the Cloudflare dashboard

1. **R2 → Create bucket**, named `littlestepz-backups`, location automatic.
2. Bucket → **Settings → Object lifecycle rules → Add rule**: delete objects 30 days after upload, whole bucket.
3. **R2 → Manage API tokens → Create API token**: permission **Object Read & Write**, applied to
   `littlestepz-backups` only, no expiry (or a long one with a calendar reminder).
4. Note the **Access Key ID**, **Secret Access Key** and the **S3 endpoint**
   (`https://<account-id>.r2.cloudflarestorage.com`). The secret is shown once.

### 2.2 On the VPS

`no_check_bucket=true` is needed because the token can't list or create buckets, only objects in this one.
Type the keys at the prompts, not on the command line, so they stay out of shell history:

```sh
read -rp 'R2 access key id: ' K; read -rsp 'R2 secret: ' S; echo; read -rp 'R2 endpoint URL: ' E
rclone config create r2 s3 provider=Cloudflare access_key_id="$K" secret_access_key="$S" \
  endpoint="$E" acl=private no_check_bucket=true > /dev/null
unset K S E
rclone lsf r2:littlestepz-backups && echo "R2 reachable"

echo 'OFFSITE=r2:littlestepz-backups/website' > /etc/website-backup.env
echo 'OFFSITE=r2:littlestepz-backups/crm'     > /etc/crm-backup.env
chmod 600 /etc/website-backup.env /etc/crm-backup.env
mkdir -p /var/log/website

/srv/littlestepz/deploy/crm/backup.sh             # Copied off-server to r2:littlestepz-backups/crm
rclone ls r2:littlestepz-backups/crm              # the .dump and .sha256 are there
```

The website's backup is tested in Phase 5, once its database holds data.

## Phase 3 — Rehearse the copy (no downtime)

The whole copy, run once into a scratch database while the site stays live. It catches problems before the real
cutover and times it.

```sh
cd /var/www/little-stepz
deploy/website/neon-copy.sh rehearse
```

What it does: checks Postgres versions (Neon's must not be newer than `ls-postgres`), dumps Neon, restores into
`littlestepz_rehearsal`, compares every table's row count, runs `prisma migrate status`, then drops the scratch
database and the dump.

Expected:
- `Dumped … in Ns` and `Restored in Ns`. **Add the two numbers**: that plus ~5 minutes is the downtime.
- `MATCH`, or a difference only on busy tables (refresh tokens, carts) because the site is live. Orders, products
  and users must match.
- `Database schema is up to date!`

If it stops with an error, nothing has changed anywhere: send the output to whoever is helping before going on.

## Phase 4 — Cutover (downtime ≈ rehearsal time + 5 minutes)

**When:** the quietest hour, e.g. 02:00–04:00 IST. Announce it if needed.

What customers see during the window: pages load but sign-in, cart and checkout fail. Razorpay retries failed
webhooks for up to 24 hours, so payments made just before the stop are confirmed afterwards. Delhivery status
webhooks during the window may be lost; Phase 5 re-checks them.

### 4.1 Safety copies (5 minutes before)

- Hostinger hPanel → VPS → **Snapshots → Create snapshot**.
- Neon console → **Branches → Create branch** from `main`, named `pre-vps-move-<date>`.
- In the admin panel, note the newest order's number.

### 4.2 Stop the backend — downtime starts

```sh
pm2 stop little-stepz-backend
pm2 list                                       # little-stepz-backend: stopped
```

### 4.3 Copy

```sh
cd /var/www/little-stepz
deploy/website/neon-copy.sh cutover
```

It refuses to start if anything is still connected to Neon or if `littlestepz` already has tables. It ends with
`MATCH: … tables, … rows` and `Database schema is up to date!`.

**If it prints `MISMATCH` or any error:** `pm2 start little-stepz-backend`. The backend still points at Neon, so
the site is exactly as before. Send the output to whoever is helping.

### 4.4 Point the backend at `ls-postgres`

In **every** file found in Phase 0, put `#` in front of the Neon line (kept for rollback) and add the new line
under it. `sed` writes the line with the password from `docker/.env`, so it is never typed:

```sh
cd /var/www/little-stepz
LSPW=$(grep '^LS_DB_PASSWORD=' docker/.env | cut -d= -f2)
NEW="DATABASE_URL=\"postgresql://littlestepz:$LSPW@127.0.0.1:5432/littlestepz?schema=public&connection_limit=10\""
for f in packages/db/.env apps/backend/.env; do        # add any other file Phase 0 found
  grep -q '^DATABASE_URL=' "$f" || continue
  sed -i "s|^DATABASE_URL=|# NEON (rollback): DATABASE_URL=|" "$f"
  printf '\n%s\n' "$NEW" >> "$f"
done
grep -n 'DATABASE_URL' packages/db/.env apps/backend/.env
```

Each file should show one commented Neon line and one active `127.0.0.1:5432` line.

### 4.5 Start the backend — downtime ends

```sh
pm2 restart little-stepz-backend --update-env
pm2 logs little-stepz-backend --lines 40 --nostream     # no P1000/P1001 errors
curl -fsS http://127.0.0.1:8000/health; echo            # {"status":"ok",…}
pm2 save
```

### 4.6 Prove it's on the new database

```sh
docker exec ls-postgres psql -U littlestepz -d postgres -Atc \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = 'littlestepz' AND backend_type = 'client backend';"
```

A number above 0 means the backend is connected to `ls-postgres`. Neon should show no compute activity from now
on (Neon console → Monitoring).

## Phase 5 — Checks after the cutover (≈30 minutes)

1. **Shop:** home, category and product pages show prices, variants and images. Sign in with email and with
   Google. Add to cart, wishlist, apply a coupon.
2. **Order:** place a small COD order, check it in My Orders and the admin panel, then cancel it. Check the push
   notification and email arrive.
3. **Admin:** order list, edit a product (save something harmless, revert), affiliate panel.
4. **Mobile app:** sign in and open an order.
5. **Missed events:** Razorpay dashboard → Webhooks: failed deliveries in the window have since succeeded (or
   retry them). Delhivery: shipments that moved during the window show the right status.
6. **Background jobs:** `pm2 logs little-stepz-backend --lines 200 --nostream`: no errors from the stock,
   shipment or auth sweepers.
7. **First backup, cron and drill:**
   ```sh
   cd /var/www/little-stepz
   deploy/website/backup.sh                       # Copied off-server to r2:littlestepz-backups/website
   deploy/website/restore-drill.sh                # must print PASS
   crontab -e                                     # add the two lines from deploy/website/crontab.txt
   ```

## Phase 6 — Rollback (keep ready for the first 24 hours)

**Before any real order lands on `ls-postgres`:** stop the backend, delete the new `DATABASE_URL` lines, remove
the `# NEON (rollback): ` prefix, `pm2 restart little-stepz-backend --update-env`. Nothing is lost: Neon is
exactly as it was at step 4.2.

**After real orders landed:** those exist only on the VPS. Stop the backend, run `deploy/website/backup.sh`,
restore that dump into a new Neon branch (`pg_restore --no-owner --no-privileges` against the branch's direct
URL), point `DATABASE_URL` at that branch, restart. So decide go or no-go within the first hour.

## Phase 7 — Everyday operations

### Deploying the website

```sh
cd /var/www/little-stepz
deploy/website/deploy.sh main
```

Backup → pull → install → `prisma generate` + `migrate deploy` → build web and backend only → `pm2 reload` →
health check on :8000/health and :3000. It ends with `Healthy: <commit> is live`. Until the cutover it skips the
backup and says so (the database is still Neon).

### Backups and restores

| Task | Command |
| --- | --- |
| Backup now | `deploy/website/backup.sh` |
| List backups | `ls -lh /var/backups/website` · `rclone ls r2:littlestepz-backups/website` |
| Prove backups restore | `deploy/website/restore-drill.sh` (must print PASS) |
| Restore into a scratch DB | `deploy/website/restore.sh /var/backups/website/website-<stamp>.dump` |
| Restore over live | `pm2 stop little-stepz-backend`, then `CONFIRM_LIVE_RESTORE=yes deploy/website/restore.sh <dump> littlestepz`, then `pm2 start little-stepz-backend` |
| Fetch from R2 first | `rclone copy r2:littlestepz-backups/website/website-<stamp>.dump .` and the `.sha256` |
| Row counts | `deploy/website/table-counts.sh` |
| SQL shell | `docker exec -it ls-postgres psql -U littlestepz -d littlestepz` |

### Looking at production data from the laptop

Port 5432 is not public. Tunnel over SSH *(laptop)*, then point Prisma Studio or a SQL client at
`127.0.0.1:15432`. Read only: never run `migrate dev` or tests against it.

```sh
ssh -N -L 15432:127.0.0.1:5432 root@187.77.187.253
```

### Local development *(laptop)*

Run the same container on Docker Desktop. It starts empty; production dumps stay off laptops (customer data).

```sh
cp docker/.env.sample docker/.env                  # set LS_DB_PASSWORD (and LS_DB_PORT if 5432 is taken)
docker compose -f docker/website-postgres.compose.yml --env-file docker/.env up -d
# packages/db/.env: DATABASE_URL="postgresql://littlestepz:<password>@127.0.0.1:5432/littlestepz?schema=public"
cd packages/db && npx prisma migrate deploy
```

Then sign up on the local site and make that account an admin:
`docker exec ls-postgres psql -U littlestepz -d littlestepz -c "UPDATE \"User\" SET role = 'ADMIN' WHERE email = '<you>';"`.
Schema changes now work offline with `npx prisma migrate dev`.

### Postgres updates

Minor versions (monthly): `docker compose -f docker/website-postgres.compose.yml --env-file docker/.env pull`
then `… up -d` (about 5 seconds of downtime). A major upgrade (17 → 18) needs a dump and restore; plan it
separately.

## Phase 8 — Retire Neon (7 days after a clean cutover)

1. Keep the final Neon dump off-server for good:
   `rclone copy /var/backups/website/neon/<neon-cutover-….dump> r2:littlestepz-backups/archive/` (the lifecycle
   rule deletes it after 30 days unless the rule is scoped to exclude `archive/`; adjust the rule first).
2. Neon console → delete the project; remove the payment method if nothing else uses it.
3. `rm /root/neon.url` and delete the `# NEON (rollback)` lines from the `.env` files.

## Troubleshooting

| Symptom | Check | Fix |
| --- | --- | --- |
| `neon-copy.sh`: "holds the pooled URL" | `/root/neon.url` | Paste the string with pooling off (no `-pooler` in the host) |
| `neon-copy.sh`: "Neon runs Postgres 18" | — | Set the image to `postgres:18-alpine` in the compose file, recreate the empty container, rerun |
| `neon-copy.sh cutover`: "other connection(s) to Neon" | The listed `application_name`/`client_addr` | Stop that process (backend, a laptop with Prisma Studio open), rerun |
| `pg_restore` error during rehearsal | The error text | Nothing changed anywhere; send the output for a look before the cutover |
| Backend logs P1001 "Can't reach database server" | `docker ps --filter name=ls-postgres` | `docker compose -f docker/website-postgres.compose.yml --env-file docker/.env up -d` |
| Backend still uses Neon after restart | Neon console shows activity; `pm2 jlist \| grep -o 'neon\.tech' \| wc -l` is not 0 | PM2 holds an old copy: `pm2 delete little-stepz-backend` then `pm2 start ecosystem.config.js --only little-stepz-backend`, `pm2 save` |
| Backup log shows an error | `tail -50 /var/log/website/backup.log` | Run `deploy/website/backup.sh` by hand; usually the container is down, R2 keys changed, or the disk is full |
