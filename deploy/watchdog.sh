#!/bin/sh
# watchdog.sh: notice from ANOTHER machine that the obs_factor observer is
# down, and say so in a webhook (Slack-compatible {"text": ...}).
#
# Run it once a minute (deploy/watchdog.launchd.plist does, on a Mac). Each
# run makes one GET of the health URL. Healthy means HTTP 200 and "ok":true
# in the body (ObsFactor.Health: the last snapshot under 30 s old and the
# ticker alive). After WATCHDOG_FAILS failed runs in a row it posts once;
# when the observer answers healthy again it posts once more. Between those
# two it is silent. State is a few lines in WATCHDOG_STATE.
#
#   deploy/watchdog.sh          check once (what launchd runs)
#   deploy/watchdog.sh test     post a test message to the webhook and exit
#   deploy/watchdog.sh status   print the state file
#
# Settings come from the environment, or from WATCHDOG_ENV (default
# ~/.config/obs-factor-watchdog/env), a file of KEY=value lines read
# without executing it:
#
#   WATCHDOG_WEBHOOK   where to post; unset: only print     (no default)
#   WATCHDOG_URL       https://factory.bobbby.online/health
#   WATCHDOG_FAILS     3     failed runs in a row before the alert
#   WATCHDOG_TIMEOUT   15    seconds for each request
#   WATCHDOG_STATE     ~/.local/state/obs-factor-watchdog.state
#   WATCHDOG_NAME      the name in messages (default: the URL's host)
#
# Exit status: 0 healthy, 1 unhealthy, 2 misconfigured. POSIX sh and curl.

set -u

conf="${WATCHDOG_ENV:-$HOME/.config/obs-factor-watchdog/env}"
if [ -f "$conf" ]; then
  # KEY=value lines; an environment variable already set wins.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      WATCHDOG_[A-Z]*=*)
        key=${line%%=*}
        case "$key" in *[!A-Z_]*) continue ;; esac
        val=${line#*=}
        val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
        eval "cur=\${$key:-}"
        [ -z "$cur" ] && eval "$key=\$val"
        ;;
    esac
  done < "$conf"
fi

URL="${WATCHDOG_URL:-https://factory.bobbby.online/health}"
WEBHOOK="${WATCHDOG_WEBHOOK:-}"
FAILS="${WATCHDOG_FAILS:-3}"
TIMEOUT="${WATCHDOG_TIMEOUT:-15}"
STATE="${WATCHDOG_STATE:-$HOME/.local/state/obs-factor-watchdog.state}"
host=${URL#*://}; host=${host%%/*}
NAME="${WATCHDOG_NAME:-$host}"

case "$FAILS" in ''|*[!0-9]*|0) echo "watchdog: WATCHDOG_FAILS must be a positive integer, got '$FAILS'" >&2; exit 2 ;; esac
command -v curl >/dev/null 2>&1 || { echo "watchdog: curl not found" >&2; exit 2; }

now=$(date +%s)
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "$(stamp) $*"; }

# ---- state: fails, alerted, since (epoch of the first failure), reason ----
fails=0; alerted=0; since=0; first=""; reason=""
if [ -f "$STATE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      fails) case "$v" in ''|*[!0-9]*) ;; *) fails=$v ;; esac ;;
      alerted) [ "$v" = 1 ] && alerted=1 ;;
      since) case "$v" in ''|*[!0-9]*) ;; *) since=$v ;; esac ;;
      first) first=$v ;;
      reason) reason=$v ;;
    esac
  done < "$STATE"
fi

save() {
  mkdir -p "$(dirname "$STATE")" || exit 2
  tmp="$STATE.tmp.$$"
  printf 'fails=%s\nalerted=%s\nsince=%s\nfirst=%s\nreason=%s\nchecked=%s\n' \
    "$fails" "$alerted" "$since" "$first" "$reason" "$(stamp)" > "$tmp" && mv "$tmp" "$STATE"
}

# ---- the webhook ----------------------------------------------------------
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  '; }

# post TEXT: 0 when the webhook answered 2xx (or there is none to answer).
post() {
  if [ -z "$WEBHOOK" ]; then
    say "no WATCHDOG_WEBHOOK; would post: $1"
    return 0
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" \
    -X POST -H 'content-type: application/json' \
    --data "{\"text\":\"$(json_escape "$1")\"}" "$WEBHOOK") || code=000
  case "$code" in
    2??) return 0 ;;
    *) say "webhook answered $code"; return 1 ;;
  esac
}

took() { if [ "$1" -lt 60 ]; then echo "under a minute"; else echo "about $(( ($1 + 30) / 60 )) min"; fi; }

case "${1:-check}" in
  test)
    post "watchdog test: $NAME is watched from $(hostname) every minute ($URL)" && say "test message posted" && exit 0
    exit 1 ;;
  status)
    [ -f "$STATE" ] && cat "$STATE" || echo "no state yet ($STATE)"
    exit 0 ;;
  check) ;;
  *) echo "usage: $0 [check|test|status]" >&2; exit 2 ;;
esac

# ---- one check --------------------------------------------------------------
body_file=$(mktemp "${TMPDIR:-/tmp}/obs-factor-watchdog.XXXXXX") || exit 2
trap 'rm -f "$body_file"' EXIT
code=$(curl -s -o "$body_file" -w '%{http_code}' --max-time "$TIMEOUT" "$URL")
rc=$?
body=$(head -c 2000 "$body_file" 2>/dev/null)
age=$(printf '%s' "$body" | sed -n 's/.*"snapshot_age_s":\([0-9][0-9]*\).*/\1/p')

healthy=0
if [ $rc -eq 0 ] && [ "$code" = 200 ]; then
  case "$body" in *'"ok":true'*) healthy=1 ;; esac
fi

if [ $healthy -eq 1 ]; then
  if [ $alerted -eq 1 ]; then
    down=$(( now - since ))
    if post "RECOVERED: $NAME is healthy again after $(took $down) (snapshot ${age:-?} s old). $URL"; then
      say "recovered after ${down}s; posted"
      alerted=0
    else
      say "recovered, but the recovery post failed; will retry"
    fi
  else
    say "ok (snapshot ${age:-?} s old)"
  fi
  fails=0; [ $alerted -eq 0 ] && { since=0; first=""; reason=""; }
  save
  exit 0
fi

# unhealthy: say why, from what came back (the body names no internals)
if [ $rc -ne 0 ]; then
  case $rc in
    6) reason="DNS lookup failed" ;;
    7) reason="connection refused" ;;
    28) reason="no answer in ${TIMEOUT} s" ;;
    35|60) reason="TLS failed" ;;
    *) reason="curl failed ($rc)" ;;
  esac
else
  why=$(printf '%s' "$body" | sed -n 's/.*"reason":"\([a-z_]*\)".*/\1/p')
  reason="answered $code${why:+ $why}${age:+, snapshot $age s old}"
  # a 200 without "ok":true: an observer from before /health was JSON, or
  # something else answering at that URL (a proxy's page, a parked domain)
  [ "$code" = 200 ] && reason="answered 200 without \"ok\":true (an observer older than /health JSON, or not the observer)"
fi

[ $fails -eq 0 ] && { since=$now; first=$(date -u +%H:%M); }
fails=$(( fails + 1 ))
if [ $alerted -eq 1 ]; then say "FAIL $fails (alerted): $reason"; else say "FAIL $fails/$FAILS: $reason"; fi

if [ $fails -ge "$FAILS" ] && [ $alerted -eq 0 ]; then
  if post "DOWN: $NAME failed $fails checks in a row, the first at $first UTC: $reason. $URL"; then
    alerted=1
    say "alert posted"
  else
    say "alert post failed; will retry next run"
  fi
fi

save
exit 1
