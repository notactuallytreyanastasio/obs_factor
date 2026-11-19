#!/bin/bash
set -euo pipefail

# Break the lab on purpose, so every status and attention rule can be seen
# for real. Each command says what it did and how to undo it.
#
#   lab/break.sh stop <service>        container down (docker stop)
#   lab/break.sh start <service>       ... and back
#   lab/break.sh crashloop on|off      relay exits 1 at boot; restart: always loops it
#   lab/break.sh eat <MiB>             relay holds MiB of live memory (limit 96m)
#                                      70 = near the limit, 200 = OOM kill + restart
#                                      loop (the file persists), 0 = release
#   lab/break.sh 5xx <blog|links|relay> on|off
#                                      /health answers 500 (whoami) / 503 (relay)
#   lab/break.sh source <docker|caddy|postgres> down|up
#                                      stop the thing a whole source reads from
#   lab/break.sh reset                 undo all of the above
#
# Postgres pressure has its own scripts: lab/db-busy.sh (commits/s) and
# lab/db-connections.sh (connection count near max_connections).

HERE="$(cd "$(dirname "$0")" && pwd)"
CADDY="${CADDY:-http://127.0.0.1:18080}"

if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi
dc() { "${DC[@]}" -f "$HERE/compose.yml" "$@"; }

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
undo() { printf '    undo: %s\n' "$*"; }

whoami_status() {  # host code
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "$2" -H "Host: $1" "$CADDY/health")
  [ "$code" = "200" ] || { echo "setting $1/health to $2 answered $code" >&2; exit 1; }
}

case "${1:-}" in
  stop)
    dc stop "${2:?service}"; say "stopped $2"; undo "lab/break.sh start $2" ;;
  start)
    dc start "${2:?service}"; say "started $2" ;;
  crashloop)
    case "${2:?on|off}" in
      on)  touch "$HERE/state/relay.crash"; dc restart relay
           say "relay exits 1 at boot; Docker restarts it with back-off"
           undo "lab/break.sh crashloop off" ;;
      off) rm -f "$HERE/state/relay.crash"; dc restart relay; say "relay boots normally" ;;
      *) echo "crashloop on|off" >&2; exit 2 ;;
    esac ;;
  eat)
    mb="${2:?MiB}"
    [[ "$mb" =~ ^[0-9]+$ ]] || { echo "eat wants a whole number of MiB, got $mb" >&2; exit 2; }
    if [ "$mb" = 0 ]; then rm -f "$HERE/state/relay.eat-mb"; else echo "$mb" >"$HERE/state/relay.eat-mb"; fi
    say "relay holds ${mb} MiB (mem_limit 96m); read by relay within 1 s"
    if [ "$mb" != 0 ]; then undo "lab/break.sh eat 0"; fi
    ;;
  5xx)
    target="${2:?blog|links|relay}"; mode="${3:?on|off}"
    case "$target:$mode" in
      blog:on|links:on)   whoami_status "$target.lab.test" 500 ;;
      blog:off|links:off) whoami_status "$target.lab.test" 200 ;;
      relay:on)  touch "$HERE/state/relay.fail" ;;
      relay:off) rm -f "$HERE/state/relay.fail" ;;
      *) echo "5xx <blog|links|relay> on|off" >&2; exit 2 ;;
    esac
    say "$target /health 5xx $mode"
    if [ "$mode" = on ]; then undo "lab/break.sh 5xx $target off"; fi ;;
  source)
    svc=""
    case "${2:?docker|caddy|postgres}" in
      docker) svc=docker-proxy ;; caddy) svc=caddy ;; postgres) svc=db ;;
      *) echo "source <docker|caddy|postgres> down|up" >&2; exit 2 ;;
    esac
    case "${3:?down|up}" in
      down) dc stop "$svc"; say "$2 source down ($svc stopped)"; undo "lab/break.sh source $2 up" ;;
      up)   dc start "$svc"; say "$2 source up" ;;
      *) echo "down|up" >&2; exit 2 ;;
    esac ;;
  reset)
    rm -f "$HERE/state/relay.crash" "$HERE/state/relay.fail" "$HERE/state/relay.eat-mb"
    dc up -d --no-recreate db blog links arena relay caddy docker-proxy >/dev/null 2>&1 || dc up -d db blog links arena relay caddy docker-proxy
    dc restart relay >/dev/null
    whoami_status blog.lab.test 200
    whoami_status links.lab.test 200
    say "reset: every service started, relay switches cleared, whoami /health back to 200" ;;
  ""|-h|--help)
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    echo "unknown command: $1 (try --help)" >&2; exit 2 ;;
esac
