#!/bin/bash
set -euo pipefail

# Request load across the lab's hostnames, through Caddy, so per-host series
# in Caddy's metrics move for real.
#
# Usage:
#   lab/load.sh                 ~10 req/s for 60 s
#   lab/load.sh -r 40 -d 300    40 req/s for 300 s
#   lab/load.sh -d 0            until Ctrl-C
#
# The mix: blog / and /health (the health path is where a whoami answers the
# status lab/break.sh 5xx sets), blog's /arena/* path route, links, relay,
# the static docs site, and ghost.lab.test, a host with no site block: Caddy
# answers it (empty 200) and does not count it, which is the production fact
# this lab exists to show.

RATE=10
DURATION=60
CADDY="${CADDY:-http://127.0.0.1:18080}"

while [ $# -gt 0 ]; do
  case "$1" in
    -r) RATE="$2"; shift ;;
    -d) DURATION="$2"; shift ;;
    -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

TARGETS=(
  "blog.lab.test /"
  "blog.lab.test /"
  "www.blog.lab.test /"
  "blog.lab.test /health"
  "blog.lab.test /arena/"
  "blog.lab.test /arena/match/1"
  "links.lab.test /"
  "links.lab.test /health"
  "relay.lab.test /"
  "relay.lab.test /health"
  "docs.lab.test /"
  "ghost.lab.test /"
)

# One batch per second: RATE requests in parallel, then sleep out the rest of
# the second. Per-status counts are printed every 10 s from real responses.
curl -s -o /dev/null --max-time 2 "$CADDY/" || {
  echo "Caddy is not answering on $CADDY: docker compose -f lab/compose.yml up -d" >&2
  exit 1
}

start=$(date +%s)
declare -i sent=0
tally=$(mktemp)
trap 'rm -f "$tally"' EXIT

while :; do
  now=$(date +%s)
  if [ "$DURATION" -gt 0 ] && [ $((now - start)) -ge "$DURATION" ]; then break; fi
  for _ in $(seq 1 "$RATE"); do
    t=${TARGETS[$((RANDOM % ${#TARGETS[@]}))]}
    host=${t% *}; path=${t#* }
    curl -s -o /dev/null --max-time 5 -w "%{http_code} $host\n" -H "Host: $host" "$CADDY$path" >>"$tally" &
  done
  wait
  sent+=$RATE
  if [ $((sent % (RATE * 10))) -eq 0 ]; then
    printf '%s  sent %d  ' "$(date +%T)" "$sent"
    sort "$tally" | uniq -c | awk '{printf "%s:%s=%s  ", $3, $2, $1}'
    printf '\n'
    : >"$tally"
  fi
  sleep_for=$(( 1 - ($(date +%s) - now) ))
  [ "$sleep_for" -gt 0 ] && sleep "$sleep_for"
done
echo "done: $sent requests"
