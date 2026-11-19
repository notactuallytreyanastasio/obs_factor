#!/bin/bash
set -euo pipefail

# Deploy obs_factor to the Hetzner box.
#
# The app runs as the obs-factor service in the blog stack's compose (that is
# where Docker, Caddy and Postgres are), but its source is its own tree at
# /opt/obs_factor. So: rsync the source, then drive compose from /opt/blog.
#
# This script never edits /opt/blog's docker-compose.yml, Caddyfile or .env.
# Wiring the service in is a one-time human step (deploy/ holds the exact
# additions); if it has not been done, the script stops and says what to do.
#
# Usage:
#   ./deploy.sh            test, sync, check wiring, rebuild, restart, health check
#   ./deploy.sh -n         dry run: list what would sync, change nothing
#                          (it does connect: the dry-run rsync runs over ssh)
#   ./deploy.sh --no-test  deploy without running the suite (say why)
#   ./deploy.sh --host user@host

HOST="${DEPLOY_HOST:-root@5.161.181.91}"
APP_DIR="/opt/obs_factor"
STACK_DIR="/opt/blog"
URL="https://factory.bobbby.online/health"
DRY=0
SKIP_TESTS=0

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1 ;;
    --no-test)    SKIP_TESTS=1 ;;
    --host)       HOST="${2:?--host needs user@host}"; shift ;;
    -h|--help)    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")"

bold() { printf '\033[1m==>\033[0m %s\n' "$1"; }
did()  { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\033[31m==> %s\033[0m\n' "$1" >&2; exit 1; }

EXCLUDES=(
  --exclude '.git' --exclude '.env' --exclude '_build' --exclude 'deps'
  --exclude '.elixir_ls' --exclude '.deciduous' --exclude '.claude' --exclude '.prs'
  --exclude 'node_modules' --exclude 'erl_crash.dump'
  # The lab is a laptop thing (and lab/state holds cookies and snapshots);
  # tests are not in the image.
  --exclude 'lab' --exclude 'test'
  # Written on the box by this script; without the exclude --delete would
  # remove it on every deploy.
  --exclude '.deployed'
)

# The suite gates the deploy on its own exit status, written to a log and
# tested directly: never through a pipe, which reports the last command's
# status instead (marginalia deployed over a red suite that way once).
if [ $SKIP_TESTS -eq 0 ] && [ $DRY -eq 0 ]; then
  bold "tests"
  log="${TMPDIR:-/tmp}/obs_factor-test.log"
  if mix test > "$log" 2>&1; then
    did "$(grep -E '[0-9]+ tests?, [0-9]+ failures?' "$log" | tail -1)"
  else
    tail -30 "$log"
    printf '\033[31m==> refusing to deploy over a failing suite\033[0m\n' >&2
    printf '    full log: %s; or ./deploy.sh --no-test to override\n' "$log" >&2
    exit 1
  fi
fi

bold "obs_factor → $HOST:$APP_DIR"

# A dry-run rsync is the source of truth for what would change. Errors are
# not swallowed: an unreachable host fails here, loudly.
changes=$(rsync -ain --delete "${EXCLUDES[@]}" "$PWD/" "$HOST:$APP_DIR/" \
  | awk '($1 ~ /^[<>ch*]/) && $2 != "./" {print $2}')

if [ -z "$changes" ]; then
  warn "nothing changed"
else
  printf '%s\n' "$changes" | awk 'NR <= 15 { print "      " $0 }'
  n=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
  [ "$n" -gt 15 ] && printf '      … and %s more\n' "$((n - 15))"
fi

proxy_changed=0
# A here-string, not a pipe: grep -q exits at the first match, and under
# pipefail the writer's SIGPIPE would turn that match into a failure.
grep -q '^deploy/docker-proxy/' <<<"$changes" && proxy_changed=1

if [ $DRY -eq 1 ]; then
  warn "dry run: would sync, check the wiring in $STACK_DIR, rebuild obs-factor$([ $proxy_changed = 1 ] && echo ', restart docker-proxy')"
  bold "dry run — nothing changed"
  exit 0
fi

ssh "$HOST" "mkdir -p $APP_DIR"
rsync -az --delete "${EXCLUDES[@]}" "$PWD/" "$HOST:$APP_DIR/"
did "synced"

# ------------------------------------------------------------ the wiring
# Read-only checks of what a human adds once. Each prints what is missing.
bold "wiring in $STACK_DIR"
missing=$(ssh "$HOST" bash -s "$STACK_DIR" <<'REMOTE'
  set -u
  cd "$1" || { echo "no $1"; exit 0; }
  services=$(docker compose config --services 2>&1) || { echo "docker compose config failed: $services"; exit 0; }
  for s in obs-factor docker-proxy; do
    printf '%s\n' "$services" | grep -qx "$s" || echo "service $s is not in docker-compose.yml"
  done
  grep -q '^factory\.bobbby\.online' Caddyfile || echo "Caddyfile has no factory.bobbby.online site"
  grep -q '^http://:9180' Caddyfile || echo "Caddyfile has no http://:9180 metrics site"
  grep -q 'per_host' Caddyfile || echo "Caddyfile has no metrics { per_host } global option"
  # Key names only; values are never printed.
  for k in OBS_FACTOR_PASSWORD OBS_FACTOR_SECRET_KEY_BASE OBS_FACTOR_DB_PASSWORD; do
    grep -q "^$k=." .env || echo ".env has no value for $k"
  done
  docker compose exec -T db psql -U blog -d postgres -tAc \
    "select 1 from pg_roles where rolname = 'obs_factor'" </dev/null 2>/dev/null | grep -q 1 \
    || echo "Postgres has no obs_factor role"
REMOTE
)

if [ -n "$missing" ]; then
  printf '%s\n' "$missing" | sed 's/^/    ✗ /'
  cat >&2 <<EOF

==> obs_factor is not wired into $STACK_DIR yet. This script does not edit
    that stack. Do these once, by hand (the files are in deploy/ here and
    in $APP_DIR/deploy on the box):

    In the blog repo, NOT on the box: blog/deploy.sh rsyncs docker-compose.yml
    and the Caddyfile over /opt/blog, so an edit made only on the box is
    silently undone by the next blog deploy.
    1. blog/docker-compose.yml: paste the obs-factor and docker-proxy
       services and the networks: block from deploy/compose.obs-factor.yml
    2. blog/Caddyfile: (cd ~/code/blog && patch -p0 Caddyfile < $PWD/deploy/Caddyfile.patch)
    3. blog/deploy.sh blog   (syncs both, reloads Caddy)

    On the box, in $STACK_DIR (.env is never synced):
    4. .env: add the keys in deploy/env.example (generate each value there)
    5. Postgres role: the command at the top of deploy/postgres-role.sql

    Then run ./deploy.sh again.
EOF
  exit 1
fi
did "obs-factor, docker-proxy, Caddy sites, .env keys and Postgres role present"

# statfs on /var/lib/obs_factor/statfs is only the root filesystem's numbers
# if that directory is on the root filesystem. Say so if it is not.
same_fs=$(ssh "$HOST" 'mkdir -p /var/lib/obs_factor/statfs && [ "$(stat -f -c %i /)" = "$(stat -f -c %i /var/lib/obs_factor/statfs)" ] && echo yes || echo no')
[ "$same_fs" = yes ] && did "/var/lib/obs_factor/statfs is on /" \
  || warn "/var/lib/obs_factor/statfs is NOT on the root filesystem: host-disk will describe another disk"

ssh "$HOST" "cd $STACK_DIR && docker compose build obs-factor && docker compose up -d docker-proxy obs-factor" </dev/null >/dev/null
did "rebuilt + restarted obs-factor"

if [ $proxy_changed -eq 1 ]; then
  # The config is a mounted directory; Caddy reads it at start, admin is off.
  ssh "$HOST" "cd $STACK_DIR && docker compose restart docker-proxy" </dev/null >/dev/null
  did "restarted docker-proxy (its Caddyfile changed)"
fi

bold "health"
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  body=$(curl -s --max-time 10 -w ' %{http_code}' "$URL" || echo ' 000')
  if [ "$body" = "ok 200" ]; then ok=1; break; fi
  sleep 3
done
if [ $ok -eq 1 ]; then did "$URL  ok 200"; else warn "$URL  answered: ${body:-nothing}"; fi

rev=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
git diff --quiet 2>/dev/null || rev="$rev+dirty"
ssh "$HOST" "echo '$rev  $(date -u +%FT%TZ)' > $APP_DIR/.deployed"

[ $ok -eq 1 ] && bold "deploy complete" || { bold "deployed, but the health check failed"; exit 1; }
