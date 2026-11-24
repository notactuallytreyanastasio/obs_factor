# Noticing that the observer is dead

The observer cannot report its own death. Two things outside the box can:

| | where it runs | what it needs | what it catches |
|---|---|---|---|
| heartbeat (`ObsFactor.Heartbeat`) | inside obs-factor, pings out | `HEARTBEAT_URL` on the box | observer wedged or dead, box down, box offline |
| watchdog (`deploy/watchdog.sh`) | another machine, polls in | a webhook URL on that machine | all of the above, plus Caddy, DNS, Cloudflare, TLS |

Either one is enough to be paged. They fail differently (the heartbeat
service can be down; the Mac can be asleep), so both is better.

Both read the same answer: `GET https://factory.bobbby.online/health`.

```
$ curl -s -w ' %{http_code}\n' https://factory.bobbby.online/health
{"ok":true,"snapshot_age_s":3,"sources_ok":8,"sources_total":9} 200
```

`ok` is true, with status 200, only when the last good snapshot is under
30 s old and the ticker is registered. Otherwise 503 and a reason:
`ticker_down`, `no_snapshot_yet`, `snapshot_stale` (no tick has finished),
`snapshot_failing` (every build since raises). Sources failing do not make
it 503; the counts are there to read. Nothing inside the box is named.

## The heartbeat (on the box)

1. Make a check that alarms when pings stop, with a 1 minute period and a
   grace of 3 to 5 minutes:
   - healthchecks.io: New check, Period 1 minute, Grace 3 minutes. Copy the
     ping URL (`https://hc-ping.com/<uuid>`).
   - Uptime Kuma: Add New Monitor, type Push, Heartbeat Interval 60. Copy the
     push URL; keep its `?status=up&msg=OK&ping=` and set
     `HEARTBEAT_METHOD=get`.
   - Better Stack: Heartbeats, Create, frequency 1 minute, grace 3 minutes.
2. Append to `/opt/blog/.env`:
   ```
   HEARTBEAT_URL=https://hc-ping.com/<uuid>
   # optional: an unhealthy observer POSTs <url>/fail and alarms at once
   # (healthchecks.io, Better Stack). Leave unset for Uptime Kuma.
   HEARTBEAT_FAIL=1
   ```
3. Pass them to the service: in `/opt/blog/docker-compose.yml`, under
   `obs-factor:` `environment:`, add
   ```
   HEARTBEAT_URL: ${HEARTBEAT_URL:-}
   HEARTBEAT_FAIL: ${HEARTBEAT_FAIL:-}
   HEARTBEAT_METHOD: ${HEARTBEAT_METHOD:-}
   ```
   (`deploy/compose.obs-factor.yml` has them already.)
4. `docker compose up -d obs-factor`. The first ping goes 20 s after boot.
   The log says `event=heartbeat.started`, then `heartbeat.pinging`; a
   delivery failure is `heartbeat.undelivered`, an unhealthy observer
   `heartbeat.skipped` (or `heartbeat.failed` with `HEARTBEAT_FAIL=1`). Each
   is logged when it starts, not every minute.

The body of each ping is one line, which healthchecks.io shows per ping:

```
ok snapshot_age=3s sources=8/9
fail snapshot_stale snapshot_age=94s sources=2/9      (only with HEARTBEAT_FAIL=1, to <url>/fail)
```

## The watchdog (on a Mac)

It needs `/bin/sh` and `curl`, nothing else. One curl a minute; after 3
failed runs in a row it posts once to a Slack-compatible webhook
(`{"text": ...}`), and once more when the observer is healthy again.

```sh
# 1. the script
mkdir -p ~/.local/bin
cp deploy/watchdog.sh ~/.local/bin/obs-factor-watchdog.sh
chmod +x ~/.local/bin/obs-factor-watchdog.sh

# 2. the webhook (a secret: not in the plist, not in git)
mkdir -p ~/.config/obs-factor-watchdog
cat > ~/.config/obs-factor-watchdog/env <<'EOF'
WATCHDOG_WEBHOOK=https://hooks.slack.com/services/T000/B000/XXXX
# WATCHDOG_FAILS=3
# WATCHDOG_URL=https://factory.bobbby.online/health
EOF
chmod 600 ~/.config/obs-factor-watchdog/env

# 3. try it by hand
~/.local/bin/obs-factor-watchdog.sh test     # posts a test message
~/.local/bin/obs-factor-watchdog.sh          # one check

# 4. launchd, every minute
sed "s|/Users/YOU|$HOME|g" deploy/watchdog.launchd.plist \
  > ~/Library/LaunchAgents/local.obs-factor.watchdog.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.obs-factor.watchdog.plist
tail -f ~/Library/Logs/obs-factor-watchdog.log
```

What the log and the webhook say, from a run against a fake observer that
went stale for four checks:

```
2026-11-24T01:39:28Z ok (snapshot 2 s old)
2026-11-24T01:39:28Z FAIL 1/3: answered 503 snapshot_stale, snapshot 94 s old
2026-11-24T01:39:28Z FAIL 2/3: answered 503 snapshot_stale, snapshot 94 s old
2026-11-24T01:39:28Z FAIL 3/3: answered 503 snapshot_stale, snapshot 94 s old
2026-11-24T01:39:28Z alert posted
2026-11-24T01:39:28Z FAIL 4 (alerted): answered 503 snapshot_stale, snapshot 94 s old
2026-11-24T01:39:28Z recovered after 0s; posted
2026-11-24T01:39:28Z ok (snapshot 2 s old)

{"text":"DOWN: factory.bobbby.online failed 3 checks in a row, the first at 01:39 UTC: answered 503 snapshot_stale, snapshot 94 s old. https://factory.bobbby.online/health"}
{"text":"RECOVERED: factory.bobbby.online is healthy again after under a minute (snapshot 2 s old). https://factory.bobbby.online/health"}
```

Other reasons it gives: `connection refused`, `DNS lookup failed`,
`no answer in 15 s`, `TLS failed`, `answered 502` (Caddy up, observer not),
and `answered 200 without "ok":true` (an observer deployed before `/health`
was JSON, or something else answering at the URL).

`obs-factor-watchdog.sh status` prints the state file
(`~/.local/state/obs-factor-watchdog.state`). Delete it to start over.

To remove: `launchctl bootout gui/$(id -u)/local.obs-factor.watchdog`, then
delete the plist, the script, the env file and the state file.

### What it does not do

- A Mac that sleeps does not check. `man launchd.plist`, StartInterval: "If
  the system is asleep during the time of the next scheduled interval
  firing, that interval will be missed". An outage that starts and ends
  while the lid is shut is never seen, and one that is still on at wake
  needs 3 more minutes. The heartbeat covers that; or keep the Mac awake
  (`pmset`, or a machine that never sleeps).
- It alerts once per outage. It never reminds.
- A webhook that is down when the alert is due is retried every minute
  until it answers 2xx; the recovery message likewise.
- The log grows one line a minute (about 30 MB a year). `: > ~/Library/Logs/obs-factor-watchdog.log`
  empties it.
