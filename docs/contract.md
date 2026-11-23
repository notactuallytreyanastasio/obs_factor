# obs_factor contract

The observer polls the box and serves one JSON snapshot. The browser draws a
factory from it. This file is the interface between the three parts; change it
only by agreement, and say so when you do.

## What was verified before any code (2026-11-18)

- The box: 4 cores, 15.6 GB, 150 GB disk at 87%. 19 containers, 18 running.
- Postgres `max_connections` is 100 and 96 were in use. **The observer holds
  exactly one connection, no pool, no database of its own.**
- `docker-compose.yml` is not the truth: `classifier`, `icecast` and an exited
  `temper-link` exist on the box and not in the file. Nodes come from Docker.
- Only `db` and `deciduous-mcp` have a Docker healthcheck. Up/down comes from
  the observer's own HTTP probes.
- `GET /containers/{id}/json` (inspect) carries every secret in `Config.Env`.
  Read `State`, `RestartCount`, `HostConfig.Memory` from it and drop the rest
  at the parse boundary. Never log, store or serve the raw body.
- Caddy on the box is 2.10.2. With `metrics { per_host }` in the global block
  and a `http://:9180 { metrics }` site, it serves the series in
  `test/fixtures/caddy_2.10.2_metrics.txt` (captured from a real 2.10.2).
  Requests to a hostname with no site block are not counted.
- Real payloads from the box are in `test/fixtures/box/capture.json`: the
  container list, two stats samples 5 s apart for five containers, three
  inspects (Env redacted), `/proc/{stat,meminfo,loadavg}` twice, 
  `pg_stat_database` rows, `statvfs("/")`.

## Rules

- **No simulated data.** A source that cannot be read is reported as failed in
  `sources`, and the nodes that depend on it say so. Never substitute a
  plausible number. A value that is not known is `null`, and the UI shows it as
  unknown, not as zero.
- Unhandled cases raise with the offending value. No silent fallbacks.
- Every claim about Docker, Caddy, Postgres or the browser is checked by
  running it.

## Environment (observer)

| var | meaning | example |
|---|---|---|
| `OBS_FACTOR_PASSWORD` | the one password; prod refuses to boot without it | |
| `SECRET_KEY_BASE`, `PHX_HOST`, `PORT` | as every Phoenix app in the stack | `PORT=4000` |
| `DOCKER_URL` | Docker Engine API over HTTP (the read-only socket proxy) | `http://docker-proxy:2375` |
| `CADDY_METRICS_URL` | | `http://caddy:9180/metrics` |
| `PG_URL` | one connection, any database; needs to read `pg_stat_database` | `postgres://blog:pw@db/postgres` |
| `HOST_PROC` | where the host's /proc is readable | `/proc` |
| `HOST_DISK_PATH` | a path on the host's root filesystem, for statfs | `/hostfs` |
| `SITES_DIR` | one subdirectory per static site Caddy serves | `/sites` |
| `TOPOLOGY` | path to the topology file | `priv/topology/prod.exs` |
| `ACCESS_LOG` | Caddy's JSON access log, read-only (Access log) | `/caddy-logs/access.log` |
| `REPORT_TOKEN` | optional bearer token sent to every `report` URL (Reports), and with every observer read forwarded to a building (Observer) | |
| `OBSERVER_ACTIONS_TOKEN` | bearer token sent with observer actions (Observer); the apps' `FACTORY_REPORT_ACTIONS_TOKEN`. Unset: every action answers 403, the observer's own VM included | |
| `CHECK_ORIGIN` | optional: page origins allowed to open the websocket, comma-separated; unset = the host of `PHX_HOST` (Live: one socket) | `//localhost,//127.0.0.1` |
| `OBJECTIVES_PG_URL` | optional: the objectives store, a database and role of its own (`deploy/objectives-db.sql`); unset, `/api/objectives` is 503 | `postgres://obs_factor_app:pw@db/obs_factor` |

Tick is 5 s. History is in memory: 5 s resolution for 1 h, 1 min for 24 h.

## Topology file (`priv/topology/*.exs`, evaluates to a map)

The topology names and places what we know about. It does not decide what
exists: every container Docker lists becomes a node whether or not it is here.

```elixir
%{
  platforms: [%{id: "main", label: "bobbby.online"}, %{id: "host", label: "the box"}],
  nodes: [
    %{id: "caddy", label: "Caddy", kind: :proxy, service: "caddy", platform: "main", pos: {2, 3}},
    %{id: "blimp-blog", label: "Blimp blog", kind: :app, service: "blimp-blog",
      platform: "main", pos: {4, 2},
      hosts: ["bobbby.online", "www.bobbby.online"],   # Caddy hosts whose requests are this node's
      via: [],                                          # path routes on someone else's host, label only
      probe: "http://blimp-blog:4100/",                 # nil = not probed
      databases: ["blog_prod"]},
    %{id: "soldat", label: "Arena", kind: :app, service: "soldat", platform: "main", pos: {6, 4},
      hosts: [], via: ["bobbby.online/arena/*"], probe: "http://soldat:8901/"},
    %{id: "db", label: "Postgres", kind: :db, service: "db", platform: "main", pos: {4, 5}},
    %{id: "site-deciduous", label: "deciduous.dev", kind: :static, site: "deciduous",
      platform: "static", pos: {0, 0}, hosts: ["deciduous.dev", "www.deciduous.dev"]},
    %{id: "deepseek", label: "DeepSeek", kind: :external, platform: "outside", pos: {0, 0}}
  ],
  # Extra belts nobody meters. Metered belts are derived, see below.
  edges: [%{from: "blimp-blog", to: "deepseek", item: "prompts"}]
}
```

- `service` matches the `com.docker.compose.service` label; `container: "name"`
  matches an exact container name instead. `service` matches only containers
  whose `com.docker.compose.oneoff` label is `False`: a `docker compose run`
  container (on the box, exited `temper-link`, labelled service `marginalia`,
  oneoff `True`) is matched by `container:` or else becomes its own unplaced
  node with `id` = its name.
- `kind`: `:proxy | :app | :relay | :db | :static | :external`.
- `pos` is `{col, row}` in building slots within its platform, not pixels.
- A container with no topology entry gets `id` = its compose service (or its
  name), `kind` `"unplaced"`, `pos` `null`, `platform` `null`.
- A topology node with a `service` and no such container is **down**.
- If two compose projects on one Docker both have a service (the lab laptop
  runs two stacks with a `db`), the container from the *home project* (the
  project that supplies most of the topology's services) is the node; the
  other is unplaced with `id` = its container name. *(backend, 2026-11-18)*
- Validated at boot; the error names the entry. Beyond the shape above
  *(backend, 2026-11-18)*: every node's `platform` must be listed in
  `platforms` (the example's `"static"` and `"outside"` must be added there);
  at most one `:proxy` and one `:db` node; `:proxy`/`:app`/`:relay`/`:db` need
  `service` or `container`, `:static` needs `site`, `:static`/`:external` take
  neither; the proxy takes no `hosts` (it shows every host Caddy reports); a
  host or a service belongs to one node only; `probe` is an http(s) URL; ids
  `internet`, `host-cpu`, `host-mem`, `host-disk` are reserved; an extra edge
  may not duplicate a derived belt. `TOPOLOGY` is a plain path (absolute or
  relative to the working directory) and is required: no topology, no boot.

Derived belts:

- `internet → caddy`: total requests/s.
- `caddy → node`: one per node with `hosts`, rate = sum of its hosts' requests/s,
  metered. One per node with only `via`, `metered: false`, rate `null`.
- `node → db`: one per node with `databases`, rate = commits/s summed over them.

Belt fields *(backend, 2026-11-18)*: `internet → caddy` has `item`
`"requests"`, `label` `"all hosts"`; `caddy → node` has `item` `"requests"`,
`unit` `"req/s"`, `label` the hosts (or `via` routes) joined with `", "`;
`node → db` has `item` `"commits"`, `unit` `"commits/s"`, `label` the
databases. Topology `edges` have `rate` `null`, `unit` `null`,
`metered: false`, `label` = `item`. A metered rate is `null` when any part of
it is unknown (first scrape, Caddy restart, source failing). Caddy series
with `handler="metrics"` are not counted: they are our own scrapes.

## Live: one socket *(2026-11-22)*

Everything the page shows live arrives over one Phoenix Channels websocket,
and every live thing on the server is published on `ObsFactor.PubSub` and
consumed by subscribing. The page makes no HTTP request on a timer: a GET is
for the first load or a resync after a reconnect (and the socket's join
replies already carry the current state, so the page needs none for that);
writes are POSTs or channel pushes, and their effects reach every viewer
through the topics.

**Connecting.** `GET /api/socket_token?origin=<location.origin>` (behind the
login) answers `{"token", "max_age_s": 60, "origin": {"ok": true} | {"ok": false, "reason"}}`.
The token is a `Phoenix.Token` carrying the session's id (minted at login, or
on the first token request of an older session). Then
`ws(s)://<host>/socket/websocket?token=...&vsn=2.0.0` (`ObsFactorWeb.UserSocket`,
websocket only, the V2 JSON serializer of `phoenix.js`). A missing,
forged or expired token is refused: HTTP 403 on the upgrade, and a
`socket refused: token <missing|invalid|expired>` warning in the log. A browser
cannot see why an upgrade failed, so the token answer carries the verdict of
the same origin check the socket makes, with what is allowed. `POST /logout`
disconnects the session's sockets (`session:<id>`).

The origin check is the endpoint's `check_origin`: in prod the host of
`PHX_HOST` (behind Caddy the browser's origin is `https://PHX_HOST` and Caddy
passes `Host` through and proxies the upgrade by itself); `CHECK_ORIGIN`
replaces it with a list (`//localhost,//127.0.0.1` in the lab); dev allows any.

**The client** is `priv/static/assets/js/bus.js` over `phoenix.mjs`, vendored
as is from `deps/phoenix/priv/static/phoenix.mjs` into
`priv/static/assets/vendor/` (no build step). `subscribe(topic, onEvent, {params, onJoin, onError}) -> unsubscribe`,
`push(topic, event, payload) -> Promise`, `onState(fn)`. It fetches a fresh
token before every (re)connect, backs off 0.5 s to 30 s, rejoins every topic
(a function `params` is re-evaluated, so the log tail rejoins with
`{after: last_id}`), shares one channel per topic among the page's
subscribers, and does not retry a join the server refused. The top bar
shows its state: `connecting`, `live` / `stale` while connected,
`reconnecting` with the reason (`observer unreachable (Failed to fetch)`),
`refused` with the reason (signed out; the origin verdict; or "the observer
answers HTTP but refused the websocket 3 times in a row"), and `last tick
failed` when a snapshot build failed.

**Topics.** Server message is what is broadcast on `ObsFactor.PubSub`;
pushes are what the channel sends the browser.

| topic | join params → reply | pushes | server message |
|---|---|---|---|
| `snapshots` | → `{snapshot}` or `{error}` (no snapshot yet, build failed) | `snapshot` (the snapshot below, the ticker's binary as a `Jason.Fragment`, not re-encoded), `error` `{error}` | `{:snapshot, json}`, `{:snapshot_error, message}` (Ticker) |
| `objectives` | → `{objectives: [row]}` or `{error}` (no store, Postgres down: the join still succeeds) | `objective` row; `list` `{objectives}` if it changed during the join | `{:objective, row}` from `ObsFactor.Objectives` on every insert, came back, cleared itself, pin, look/done/reopen and the ≤30 s `last_seen_at` write; row as `GET /api/objectives`, with `events` |
| `actions` | → `{}` | `action` map | `{:action, map}`, published by whoever acts (the engine); relayed as is, nothing kept |
| `logs` | `{after: id}` → `{events, last_id, kept}`, every kept event above `after` | `events` `{events: [event]}` per event | `{:log, event}` from `ObsFactor.LogRing`, event as `GET /api/logs` |
| `observer:<node>:<member or ->:<view>` | → last payload or `{}`; refused with `{reason}` for an unknown node or view or a wrong member | `feed` `{at, data}` or `{at, error}` | `{:feed, topic, payload}` from the topic's feed (`ObsFactor.Feeds.ObserverViews`; Observer, "On the bus") |
| `history:<node>:5s` / `:1m` | same | same | `ObsFactor.History.query/2` every 15 s / 60 s |
| `builds:<id>` / `builds:<id>:log` | same | same | the builder's job (log tail) / whole log, every 2 s |
| `tape` | → `{range: {from, to, frames}, tick_ms}` or `{error}` (no store, Postgres down: the join still succeeds) | `tick` `{at, alerts, warns, down, blocked, rps, err_rps, fires, top, metrics}` per frame written (`fires`: how many attention lines; `top`: the first six; `metrics`: the board's numbers per node) | `{:tape_frame, tick}` from `ObsFactor.Tape` after each insert |

Channel writes on `objectives`: `pin` `{node, title, note, by}` and `act`
`{id (integer), action: look|done|reopen, note, by}`, replied with the row or
`{error}`. `POST /api/objectives[/:id]` does the same and is broadcast the same.
Channel reads on `tape` (times unix ms, a window at most 31 days), replied
with the value or `{error}`: `index` `{from, to, buckets}` → `{from, to,
step, buckets: [[t, frames, alerts, warns, down, err_rps, rps]]}` (worst of
each column; empty columns left out: a gap in the tape); `frame` `{at}` →
`{at, next, snapshot}` (the last frame at or before `at`, or the first after
it; `next` nil at the live edge); `series` `{from, to, points}` → `{series: [[at, {node: {key: n}}]]}` (the board's
numbers, at most `points` frames, every k-th, the newest always in); `marks` `{from, to}` → `{marks: [[at, kind,
objective_id, node, severity, title, by]]}` (objective events, newest 600);
`lanes` `{from, to}` → `{lanes: [[node, severity, from, to, frames, text]]}` (each building's runs of alerts and warnings, a gap over 90 s ending one); `windows` → `{windows: [window]}`; `insights` `{from, to}` → `ObsFactor.Insights.compute/2` (`score`, `calm`,
`hot`, `repeat`, `peaks`, `worst`). The tape is `tape_frames` in the
objectives database: every tick for 6 h, then one a minute for 7 days,
except inside a saved window (`tape_windows`), which keeps every frame
until it is pruned. Writes on `tape`: `save_window` `{from, to, title,
note, by}` (with `id`: change one, which is how it is trimmed or
renamed) → `{window}`; `prune_windows` `{ids}` → `{pruned}` (marked, not deleted: listed with `pruned_at` and its frames still kept for an hour, then gone); `restore_windows` `{ids}` → `{restored}` (an undo within that hour); after either,
every viewer gets `windows` `{windows}`, and the join reply carries
`windows` too.
Channel write on `observer:*`: `action` `{path, params, by}` on the topic's
node and member, replied with the engine's answer or `{error, status}`, and
broadcast on `actions` (Observer, "On the bus"). `POST
/api/nodes/:id/observer/*path` does the same.

A join reply is read before the channel's PubSub subscription exists (Phoenix
subscribes after `join/3` returns), so each channel re-reads once it is
subscribed and pushes what changed in between: the same item can arrive
twice around a join, never zero times. Log events dedupe on `id`.

**Feeds.** `ObsFactor.Feeds`: a `Registry` and a `DynamicSupervisor` of one
`Feed` per topic, however many browsers watch it. Started by the first
`Feeds.subscribe(topic, {module, args, interval_ms})` (from a channel
process, which it monitors); fetches at once and every `interval_ms` in a
task (a fetch still running skips the period); broadcasts every result,
errors as `{at, error}` (a raise is an error with its message); hands the last
payload to each newcomer; stops 10 s after its last subscriber left.
`Feeds.refetch(topic)` / `Feeds.refetch_prefix(prefix)` fetch at once,
outside the interval (a fetch in flight is followed by one more when it
ends); actions use it so the floor shows their effect without waiting.
Built-in: `observer:observer:-:beam` (`ObsFactor.Beam.report/1` with the
last 500 log events at every level, every 2 s; the "Under the hood" panel
filters levels itself). To add a view, implement `ObsFactor.Feeds.View`:

```elixir
defmodule MyViews do
  @behaviour ObsFactor.Feeds.View
  # {:ok, {module, args, interval_ms}} | {:error, reason} (refuses the join) | :pass (not mine)
  def resolve("observer:" <> rest), do: ...
  def resolve(_), do: :pass
  def fetch(args), do: {:ok, data} # or {:error, reason}; data encodes to JSON
end

config :obs_factor, :feed_views, [MyViews]
```

`ObsFactorWeb.UserSocket` routes `observer:*`, `history:*` and `builds:*` to
`ObsFactorWeb.FeedChannel`; a topic no resolver claims is refused with
`{reason: "no feed serves \"...\""}`. Feeds are bounded: one socket holds at
most 150 feed joins (`config :obs_factor, :feeds_per_socket`) and the
observer runs at most 1000 feeds (`:feeds_max`); past either the join is
refused with `{reason: "this page already holds 150 feeds ..."}` or
`{reason: "1000 feeds are running ..."}`. A `proc:<pid>` or `tree:<app>`
topic is not checked against the node before it starts (a sub-app is
asked over HTTP); a made-up one is a feed of 404 errors. Configured resolvers:
`ObsFactor.Feeds.ObserverViews` (every other `observer:*` topic, below).

`GET /api/snapshot`, `/api/stream` (SSE), `/api/beam`, `/api/logs`,
`/api/history`, `/api/builds/:id[/log]` stay for scripts and anything
outside the page; the page uses none of them.

## `GET /api/snapshot` and the `snapshot` SSE event on `GET /api/stream`

```json
{
  "at": "2026-11-18T22:34:47Z",
  "tick_ms": 5000,
  "sources": {
    "docker":   {"ok": true,  "at": "2026-11-18T22:34:47Z", "error": null},
    "caddy":    {"ok": false, "at": null, "error": "connection refused"},
    "postgres": {"ok": true,  "at": "...", "error": null},
    "host":     {"ok": true,  "at": "...", "error": null},
    "probes":   {"ok": true,  "at": "...", "error": null},
    "sites":    {"ok": true,  "at": "...", "error": null}
  },
  "host": {
    "cores": 4, "cpu_used_cores": 0.21, "load1": 0.03,
    "mem_used_bytes": 5165285376, "mem_total_bytes": 16368271360,
    "disk_used_bytes": 134217728000, "disk_total_bytes": 161061273600,
    "disk_avail_bytes": 20938870784
  },
  "platforms": [{"id": "main", "label": "bobbby.online"}],
  "nodes": [{
    "id": "blimp-blog",
    "label": "Blimp blog",
    "kind": "app",
    "platform": "main",
    "pos": [4, 2],
    "status": "working",
    "reason": null,
    "headline": {"value": 3.2, "unit": "req/s"},
    "container": {
      "name": "blog-blimp-blog-1", "state": "running", "status_text": "Up 13 days",
      "uptime_s": 1123200, "restarts": 0, "oom_killed": false,
      "cpu_cores": 0.007, "mem_bytes": 360448000, "mem_limit_bytes": 1610612736,
      "net_rx_bps": 5120.0, "net_tx_bps": 20480.0
    },
    "probe": {"ok": true, "code": 200, "ms": 12},
    "hosts": [{"host": "bobbby.online", "rps": 3.2, "err_rps": 0.0, "avg_ms": 8.1}],
    "via": [],
    "holds": [],
    "facts": [{"label": "memory", "value": "344 MB of 1.5 GB"}]
  }],
  "edges": [{
    "id": "caddy>blimp-blog", "from": "caddy", "to": "blimp-blog",
    "item": "requests", "rate": 3.2, "unit": "req/s", "metered": true,
    "label": "bobbby.online"
  }],
  "attention": [{"node": "db", "severity": "alert", "text": "Postgres at 96 of 100 connections"}]
}
```

- `status`: `"working"` (running and traffic or CPU in the last minute),
  `"idle"` (running, nothing happening; also a one-shot container that exited 0),
  `"blocked"` (running but something is wrong: see `reason`),
  `"down"` (not running, probe failing, restart loop, missing),
  `"unknown"` (the source that would tell us is failing).
- `reason` is a short human phrase whenever status is not working/idle.
- `kind` in JSON: `"proxy" | "app" | "relay" | "db" | "static" | "external" |
  "resource" | "source" | "unplaced"`. Three `resource` nodes always exist:
  `host-cpu`, `host-mem`, `host-disk`. One `source` node always exists:
  `internet`. `container` is `null` for static, external, resource, source.
- `mem_limit_bytes` is `null` when the container has no limit (Docker reports
  the host's total; treat a limit ≥ host memory as none).
- `holds`: what a node stores. For `db`, one entry per database
  `{"label": "blog_prod", "bytes": 2595225600}`. For `static`, one entry with
  the site's size. For `host-disk`, used and free.
- `facts`: label/value strings for the inspector, already formatted.
- Power lines are not edges. The browser draws one from `host-cpu` and one
  from `host-mem` to every node with a `container`, from `cpu_cores` and
  `mem_bytes`.
- `attention` is ordered worst first. Severities: `"alert"`, `"warn"`.
- `probe` is `null` when the node is not probed, else `{"ok", "code", "ms",
  "error"}`; `code` and `ms` are `null` when nothing answered, and `error` is a
  short string when `ok` is false (`"connect ECONNREFUSED skyfeed:4000"`), else
  `null`. *(added by the frontend, 2026-11-18)*
- `sources.*.at` is the time of the last successful read: it stays at the old
  value (or `null` if never) while `ok` is false. *(clarified by the frontend)*
  A failed read serves no data from earlier reads; a collector with no result
  for three of its intervals is reported failing ("no result for N s").
- `host.disk_avail_bytes` is space available to non-root (statfs `f_bavail`).
  Disk use is counted the way `df` does: used / (used + available); the box's
  87% is this. `host-disk`'s headline is that percentage, unit `"%"`, and its
  `holds` are `used` and `free` (= available). Every `host` field is `null`
  while the host source fails. *(backend, 2026-11-18)*
- Headline units *(backend)*: `"req/s"` (nodes with `hosts`, the proxy,
  `internet`), `"commits/s"` (db), `"B/s"` (relay without hosts, rx + tx),
  `"cores"` (other container nodes, `host-cpu`), `"B"` (`host-mem`), `"%"`
  (`host-disk`). `value` is `null` when unknown. A static node without hosts
  and an external node have `{"value": null, "unit": null}`.
- `external` nodes are `"unknown"` with reason `"not observed"`: nothing
  measures them. *(backend)*
- Resource nodes have `pos` `null` and `platform` `"host"` when the topology
  lists a platform with id `"host"`, else `null`. `internet` has both `null`.
  *(backend)*
- A probe is `ok` when anything answers with a status below 500 (a redirect to
  a login page, a 404 on `/`: the process is serving). Redirects are not
  followed; timeout 2 s. *(backend)*
- `attention[].node` is `null` for a failing source
  (`"caddy source failing: connection refused"`). *(backend)*
- One-shot (`idle` when exited 0) means the oneoff label, or a restart policy
  of `no`/`on-failure`: Docker will not start it again, so exit 0 is done.
  A container in `restarting` whose count has not been seen to rise reads
  `"restarting"`, not a count. *(backend)*
- Before the first tick `GET /api/snapshot` answers 503
  `{"error": "no snapshot yet"}`; if building a snapshot raises, 500
  `{"error": "snapshot build failed: ..."}` (never the previous tick).
  *(backend)*

## `GET /api/history?node=ID&res=5s|1m`

```json
{"node": "blimp-blog", "res": "5s", "series": [
  {"key": "cpu_cores", "label": "CPU", "unit": "cores", "points": [[1795041305000, 0.007]]}
]}
```

Points are `[unix_ms, value|null]`, oldest first. Unknown node is 404.
*(backend, 2026-11-18)*: missing `node` or a `res` other than `5s`/`1m` is 400;
`res` defaults to `5s`. A node is known once any tick recorded it. Series keys,
present only where they apply: `rps`, `err_rps`, `avg_ms` (nodes with hosts,
the proxy; `internet` has `rps`), `cpu_cores`, `mem_bytes`, `net_rx_bps`,
`net_tx_bps` (container nodes), `commits_per_s`, `connections` (db),
`cpu_used_cores` (`host-cpu`), `mem_used_bytes` (`host-mem`), `disk_used_pct`
(`host-disk`), `bytes` (static). A `1m` point is the mean of that minute's
non-null 5 s values; the `1m` series is empty until the first minute closes.

## `GET /api/beam?level=debug|info|warning|error` *(2026-11-20)*

The observer looking at itself, for the "Under the hood" panel and the tour.
Read at request time; nothing is cached or estimated (`ObsFactor.Beam`).

```json
{"at": "...", "log_kept": 500,
 "vm": {"node", "otp", "erts", "elixir", "uptime_s", "schedulers", "run_queue",
        "process_count", "process_limit", "port_count", "atom_count", "ets_count",
        "memory": {"total", "processes", "ets", "binary", "code", "atom", "system"}},
 "processes": [{"id": "Docker", "type": "worker", "pid": "<0.1569.0>", "alive": true,
   "status": "waiting", "message_queue_len": 0, "memory_bytes": 230000, "reductions": 81234,
   "current_function": ":gen_server.loop/5", "links": 2,
   "source": {"name": "docker", "ok": true, "error": null, "last_ok_at": "...",
              "attempted_ms_ago": 1000, "max_age_ms": 15000}}],
 "tables": [{"name": "Sources", "type": "set", "size": 7, "memory_bytes": 51896, "owner": "<0.1554.0>"}],
 "log": [{"at": 1795128738444, "level": "info", "text": "source docker: ok",
          "where": "ObsFactor.Collector.log_transition/3", "pid": "<0.1569.0>"}]}
```

`processes` is the top of `ObsFactor.Supervisor`; a collector's row has
`source`, the raw entry from `ObsFactor.Sources`. A child whose init returned
`:ignore` has `pid` `":undefined"` and `alive: false`. `log` is
`ObsFactor.LogRing`: the newest 200 events at `level` or worse, oldest first,
from the last 500 kept in memory since the ring started (boot lines before it
are only on stdout). Requests to `/api/beam` itself are not logged. A `level`
outside the list is 400.

## `GET /api/logs?after=ID` *(2026-11-20)*

The log ring for the log explorer: `{"events": [...], "last_id": 123, "kept": 2000}`,
every event with an id above `after` (default 0: all kept), oldest first. An
event is `{id, at, level, text, where, pid, attrs}`; `attrs` is the Logger
metadata minus process plumbing (`request_id`, `source` from the collectors,
`file`, `line`, `domain`, `application`, ...), atoms as bare strings, nil
values left out. Every event below carries `event` and its fields there, so
the explorer's `event:`, `node:`, `source:` searches and facets read them
instead of the message text. Ids only grow, so `after=last_id` tails. A
non-integer `after` is 400. Not logged itself.

## Logs: stdout *(2026-11-23)*

In prod (and the lab container, which runs the prod release) stdout is one
JSON object per line, written by `FactoryReport.JSONFormatter`: the shape
every app on the box that vendors factory_report writes, so one pipeline
aggregates them all. Dev and test write text (`[warning] source docker: ...`).
`config :obs_factor, :log_formatter` holds the formatter and its field list.

```json
{"time":"2026-11-23T17:22:20.850Z","level":"warning","msg":"action proc/0.1637.0/gc on observer by bg (curl): ok","app":"obs_factor","module":"ObsFactor.ObserverProxy","request_id":"GOq8ZGW-n-FLqVAAAAcC","page":null,"event":"action.done","source":"actions","node":"observer","member":null,"action":"gc","target":"0.1637.0","args":null,"by":"bg (curl)","path":"proc/0.1637.0/gc","status":200,"took_ms":0.053,"error":null}
{"time":"2026-11-23T17:22:20.850Z","level":"info","msg":"POST /api/nodes/observer/observer/proc/0.1637.0/gc 200 in 0.256 ms","app":"obs_factor","module":"ObsFactorWeb.Log","request_id":"GOq8ZGW-n-FLqVAAAAcC","page":null,"event":"http.request","method":"POST","path":"/api/nodes/observer/observer/proc/0.1637.0/gc","route":"/api/nodes/:id/observer/*path","handler":"ObsFactorWeb.ObserverController.act","status":200,"took_ms":0.256}
```

The first seven keys are always there, in this order, `null` when empty:
`time` (UTC, ms), `level`, `msg` (the human line), `app` (`"obs_factor"`),
`module`, `request_id` (`Plug.RequestId`, inside a request), `page`
(factory_report's attribution; `null` here, the observer does not run
`FactoryReport`). After them come the fields of the event, under the names
below; a field the event passed as nil is `null`, one it does not have is
absent. `took_ms` is a float to the microsecond, except the collectors'
whole milliseconds.

| `event` | level | fields | from |
|---|---|---|---|
| `http.request` | info | `method`, `path`, `route` (the router pattern, null for static files), `handler` (`Controller.action`), `status`, `took_ms` | every request but `/api/beam` and `/api/logs` (`ObsFactorWeb.Endpoint.log_level/1`) |
| `http.error_rendered` | `render_errors: [log: ...]`, debug by default (so not in prod) | `method`, `path`, `status`, `kind`, `reason` (the exception module) | an exception rendered as an error page |
| `socket.connected` / `socket.refused` | info / warning | `transport`, `took_ms`; refused: `reason` (`token missing`, `token invalid`, `token expired`) | `/socket` connects |
| `channel.joined` / `channel.refused` | info / warning | `topic`, `channel`, `took_ms`; refused: `reason`, the join's reply | every channel join but Phoenix's heartbeat topic |
| `action.done` / `action.refused` | warning | `source: "actions"`, `node`, `member`, `action` (last path segment: `gc`, `kill`, `exit`, `restart`, `level`, `builds`), `target` (the segments between: a pid, an app), `args` (`reason="shutdown"`, ...), `path`, `by`, `status`, `took_ms`, `error` | every observer action and `POST /api/builds`, done or refused (Observer, "Pass-through") |
| `source.failed` | warning | `source`, `reason`, `took_ms`, `previous_error` when the error changed | a collector's new or changed error |
| `source.ok` / `source.recovered` | info | `source`, `took_ms`; recovered: `previous_error` | its first ok since boot / an ok after an error |
| `snapshot.failed` | error | `kind` (the exception), `reason`, `stacktrace` | `ObsFactor.Ticker` |
| `objectives.failed` / `objectives.recovered` | error / info | `source: "objectives"`, `reason` / `previous_error` | the store failing (at most once a minute) and answering again |
| `objective.changed` | info | `source: "objectives"`, `objective_id`, `node`, `action` (the event kind: `seen`, `came back`, `cleared itself`, `pinned`, `looking`, `crossed off`, `reopened`), `by` | every objective event written |
| `objective.event_failed` | warning | as `objective.changed`, and `reason` | the event row could not be written |
| `build.started` | info | `job`, `mode`, `fqdn` | the builder (`OBS_ROLE=builder`) |
| `build.finished` | info | `job`, `status`, `reason` (the job's error, or null) | |
| `build.crashed` | error | `job`, `reason` | the build runner died |
| `config.password_missing` | warning | | boot without `OBS_FACTOR_PASSWORD` outside prod |

Not structured, and why: lines other libraries write themselves (Bandit's
startup and crash reports, Phoenix's `Ignoring unmatched topic`, OTP
supervisor and crash reports) have the seven keys and no `event`; the
vendored factory_report's own `factory_report observer action: ...` line
(when another app's engine acts) is unchanged, since that file ships to the
other apps. Phoenix's debug lines (`Processing with ...`, `HANDLED ...
INCOMING`, socket drain) are gone with `config :phoenix, :logger, false`;
nothing replaces them. Builder job step output goes to the job's own log
(`GET /api/builds/:id/log`), not to stdout.

## `GET /api/builds/:id/log` *(2026-11-20)*

The whole job log from the builder's file (`/builder/api/jobs/:id/log`), up
to its last 20000 lines: `{"id", "log": [{"t", "step", "line"}]}`. The job
in `GET /api/builds/:id` carries only the last 400. Unknown job is 404.

## `/api/objectives` *(2026-11-22)*

Mission objectives (`ObsFactor.Objectives`): what the floor raised, kept
until someone has looked. Same session as every `/api` route (401 without).

- `GET /api/objectives` → `{"objectives": [...]}`: every undone objective
  and those done in the last 24 h, newest first.
- `POST /api/objectives` with `{node, title, note, by}` → 201 and the new
  objective: a pin (`source: "pin"`, `severity: "warn"`). A pin never clears
  itself.
- `POST /api/objectives/:id` with `{action: "look" | "done" | "reopen", note, by}`
  → 200 and the objective after it.

An objective: `{id, key, source: "rule" | "pin", node, severity: "alert" | "warn",
title, first_text, state, opened_at, last_seen_at, cleared_at, done_at,
done_by, looking_by, note, seen_count, evidence, events: [{at, kind, by, note}]}`.
`node` is a floor node id, or null for what is not a building (a failing
source). `evidence` is the node's `{label, status, reason, headline}` when
the rule first saw it. `events` are the last 20, oldest first; kinds are
`seen`, `came back`, `cleared itself`, `pinned`, `looking`, `crossed off`,
`reopened`.

States: `open` → `looking` (look) → `done` (cross off). A rule objective not
seen for 60 s goes `open`/`looking` → `cleared`; seen again it is `open`
with `seen_count + 1`. One undone objective per `key` (the node and the text
with every number blanked), so a rule with a changing number is one
objective. `by` is a name the person typed, not an identity.

Errors, each `{"error": text}`: 503 `no objectives store: OBJECTIVES_PG_URL is not set`
when the observer has no store (the page hides Missions when the
`objectives` join reply's error starts with this),
503 with Postgres's reason when it has one but cannot use it, 404
`no such objective`, 409 `cannot <action> an objective that is <state>` or
`this came back since and is open as a newer objective` (reopen yields to
a newer one), 400 for an action outside the three or an id that is not an
integer.

## Building apps *(builder prototype, 2026-11-19)*

The observer can show, and start, apps that a separate **builder** makes. The
builder is the same release run with `OBS_ROLE=builder`: it holds Docker
write, git and the agent CLI, which the observer never does. Its settings
are in `lib/obs_factor/builder/config.ex`; the lab runs it with
`lab/builder.sh`.

Observer environment, both optional: `BUILDER_URL` (the builder's base URL)
and `BUILDER_TOKEN` (bearer token). Unset, there is no builder source and
the snapshot's `builder` is `null`.

Additions to the snapshot:

- `builder`: `null`, or `{"domain": "lab.test", "modes": ["github", "route"]}`
  while the builder source is ok.
- `sources.builder`: present only when `BUILDER_URL` is set.
- Every node has `build`: `null`, or the latest job for that node's id:
  `{"id", "name", "fqdn", "mode", "repo", "ref", "commit", "status"
  ("running" | "failed" | "live"), "step", "steps": [{"name", "state"
  ("pending" | "running" | "done" | "failed"), "note"}], "error",
  "created_at", "plan_summary"}`. `plan_summary` is `null` until the agent's
  plan passes validation, then `{"summary", "notes", "port", "health",
  "secrets", "dockerfile"}` (secret *names* only).
- `kind` `"construction"`: a job whose app has no running container yet (or
  a route-only lot). `container` is `null`; `hosts` is the job's hostname,
  read from Caddy like any host, with its belt from the proxy. `headline` is
  `{"value": <percent of steps done>, "unit": "% built"}`. Status: running ->
  `working` (reason `"building: <step>"`), failed -> `down` (reason
  `"build failed at <step>: <error>"`, and an alert), finished -> `idle`.
  Platform `"built"` when the topology lists it, else `null`.
- Containers place themselves with labels: `obs_factor.id` (required),
  `obs_factor.label`, `obs_factor.kind` (`app` | `relay`, default `app`),
  `obs_factor.hosts` (comma separated), `obs_factor.probe`,
  `obs_factor.platform`. Such a node has `pos` `null` (next free slot of its
  platform) and is probed like a topology node. Labels that would take an
  existing id or host, or carry a bad probe URL, are not used: the container
  stays unplaced and a `warn` says why. So does a job named like a topology
  node. Labels never carry secrets.

Endpoints (behind the session, forwarded to the builder; status and body
are the builder's, 502 when it cannot be reached, 404 when none is
configured):

- `POST /api/builds` JSON `{"name", "mode": "github" | "route", "repo",
  "ref"}` -> 201 the job, or 422 `{"error"}`. `name` is 2-30 of `[a-z0-9-]`,
  starting with a letter; `repo` must be `https://github.com/<owner>/<repo>`.
- `GET /api/builds/:id` -> the job with `"log": [{"t", "step", "line"}]`
  (the last 400 lines).

The builder's own API is `/builder/api/jobs` (GET list, POST create) and
`/builder/api/jobs/:id`, bearer token required, 404 on an observer.

## Auth

- `GET /login` serves `priv/static/login.html`. `POST /login` with form field
  `password`: on success sets the session and redirects to `/`; on failure
  redirects to `/login?error=1`. `POST /logout` clears it.
- `/`, `/api/*` require the session. `/api/*` answers 401 JSON without it;
  `/` redirects to `/login`. Static assets under `/assets/*` are public.
- `GET /health` is public and answers `ok` (the deploy check and Caddy use it).
- *(backend, 2026-11-18)* `/login` and `/logout` take no CSRF token (the
  frontend's forms are static). The session cookie is signed, `HttpOnly`,
  `SameSite=Lax`, 30 days, and `Secure` in prod. `/health` is exempt from the
  prod HTTPS redirect. If `login.html` or `index.html` is missing, the answer
  is a 500 naming the file.

## Who owns what

- `lib/`, `config/`, `mix.exs`, `test/` (except fixtures already there): backend.
- `priv/static/**`, `scripts/dev-static.mjs`: frontend.
- `lab/`, `Dockerfile`, `.dockerignore`, `deploy.sh`, `deploy/`, `priv/topology/*.exs`,
  `README.md`: lab and wiring.

## Per-subdomain detail *(agreed 2026-11-19)*

More of what Caddy already serves per host, and a building of its own for
every subdomain. Same rule as everything else: unknown is `null`, never zero.

**Topology.** A node may carry `style: "press"`: the name of the building the
browser draws for it. A lowercase word (`\A[a-z][a-z0-9-]*\z`, checked at boot). It is passed
through untouched as `"style"` on the node (`null` when absent, and on every
node the topology does not list). The observer does not know the names; a
name the browser does not know draws the building of the node's `kind`.

**`hosts[]`** entries gain, next to `rps`, `err_rps`, `avg_ms`:

```json
{"host": "bobbby.online", "rps": 3.2, "err_rps": 0.0, "avg_ms": 8.1,
 "codes": {"2xx": 3.0, "3xx": 0.15, "4xx": 0.05, "5xx": 0.0, "other": 0.0},
 "in_bps": 310.0, "out_bps": 48211.5, "in_flight": 2}
```

- `codes`: req/s by status class, from
  `caddy_http_request_duration_seconds_count{code,host}`. `"other"` is every
  code outside 200-599 (101 upgrades, Caddy's `0`). `codes` is `null` when
  `rps` is `null`; when Caddy is read and has never seen the host, every class
  is `0.0`. `err_rps` stays what it was (the `5xx` class).
- `in_bps`, `out_bps`: request and response body bytes per second, from
  `caddy_http_request_size_bytes_sum` and `caddy_http_response_size_bytes_sum`.
  `null` and `0.0` exactly as `rps`.
- `in_flight`: `caddy_http_requests_in_flight{host}` summed over handlers, an
  integer. A gauge, so it is known whenever Caddy is read, on the first scrape
  and across a restart too (when the rates are `null`); `null` only while the
  Caddy source fails; `0` for a host Caddy has never seen. *(backend)*
- `codes` need not add up to `rps`: `rps` counts requests as they start
  (`caddy_http_requests_total`), `codes` as they finish (the duration count),
  so a long request lands in a later tick. *(backend)*
- A duration series without a numeric `code`, or a fractional in-flight
  value, fails the Caddy source for that tick with the offending value.
  *(backend)*
- As everywhere, series with `handler="metrics"` are not counted.

**Edges.** Every edge has `"codes"`: on `internet>caddy` and on metered
`caddy>node` belts it is the class rates summed over the belt's hosts (`null`
if any part is unknown); on every other edge `null`.

**History.** New series where a node has hosts (and on the proxy):
`rps_4xx` ("4xx", req/s), `out_bps` ("Bytes out", B/s), `in_flight`
("In flight", requests). Summed over the node's hosts; `null` if any part is
unknown.

**Facts.** A host's fact line may also say what is in flight and bytes out.

**What the browser does with it** *(frontend)*. Buildings by `style`:
`press`, `foundry`, `switchyard`, `studio`, `library`, `conservatory`,
`observatory`, `control`, `arena`, `greenhouse`, `arcade`, `lab`, `stage`
(`priv/static/assets/js/styles.js`). Items on a request belt are coloured by
status class in the proportions of the belt's `codes`; a belt's rails take
the colour of the building it feeds. Every container building carries a
memory gauge (of its limit when it has one, marked with a red tick, else of
the box's memory) and one crate at its dock per request in flight (at most
eight drawn). The database's yard holds one container per fixed number of
bytes, coloured by database; the inspector says how many bytes that is.

## Access log *(agreed 2026-11-19)*

Caddy's counters know hostnames, not paths. A seventh source, `access`, tails
Caddy's JSON access log and adds what the counters cannot: path routes
metered, the busiest paths of each node, latency percentiles, who is asking.

**The file.** `ACCESS_LOG` is its path inside the observer (`/caddy-logs/access.log`);
unset, the source fails with `ACCESS_LOG is not set`. One JSON object per
line, as Caddy 2.10.2 writes it with the `(access)` snippet in
`deploy/Caddyfile.access` (captured live, 2026-11-19):

```json
{"level":"info","ts":1795071671.7652287,"logger":"http.log.access.log0","msg":"handled request","request":{"proto":"HTTP/1.1","method":"GET","host":"a.test","uri":"/arena/x"},"bytes_read":0,"duration":0.000152417,"size":5,"status":200,"country":"US","ua":"Mozilla/5.0 test"}
```

`uri` has no query string (Caddy strips it before writing), there are no
headers and no client address in the file, `country` is Cloudflare's
`Cf-Ipcountry` (`""` without it), `ua` the User-Agent, `duration` seconds,
`size` response bytes. A 5xx line has `"level":"error"`. Nothing else is
written to this file's lines that the observer relies on.

**Reading.** Each tick the collector reads what was appended since its last
read. On its first read it starts at the end of the file: history is not
replayed. A new inode, or a file shorter than the offset, is a rotation:
reading restarts at byte 0 of the new file and whatever was left unread in
the old one is lost (said in the source's facts, not hidden). A last line
without a newline waits for the next tick. More than 8 MiB appended in one
tick: the oldest excess is skipped and counted as `skipped_bytes`. A line
that is not the object above is counted in `bad_lines` and never crashes the
collector. A missing or unreadable file fails the source with the reason.
The observer stores no line: only the counts below, in memory.

**Whose request it is.** The node whose `via` pattern matches `host + path`
(`*` matches anything, the longest pattern wins), else the node that lists
the host in `hosts`, else nobody (`unrouted`, shown on the proxy).

**What the snapshot gains** (every field `null` while the source fails or has
not read twice; rates are over the tick, tables over the last 300 s):

- `sources.access`, like the other six.
- Every node: `"routes"`, at most 8 rows, busiest first:
  `{"path": "/arena/", "count": 42, "rps": 0.14, "errors": 0, "p95_ms": 12.0}`
  (`count`, `errors` = 5xx, over 300 s; `rps` = count / 300). Paths are cut
  at 80 characters; a node keeps at most 200 distinct paths per window and
  folds the rest into one row with `"path": "(other)"`. `[]` when it had no
  requests; `null` when unknown.
- Every node: `"latency"`: `{"p50_ms": 3.1, "p95_ms": 40.2, "p99_ms": 180.0, "count": 512}`
  over 300 s, `null` when unknown or when `count` is 0.
- A node with `via` gains `"via_rps"` (requests/s over the tick on its path
  routes) and `"via_codes"` (the five classes, as on hosts).
- A node with `via` and no `hosts`: its `caddy>node` belt is
  `"metered": true` with `rate` = `via_rps` and `codes` = `via_codes` while
  the source is ok, and its headline is `{"value": via_rps, "unit": "req/s"}`.
  While the source fails the belt is as before: `metered: false`, `rate: null`.
- A host's own belt and `rps` still come from Caddy's counters and still
  include the path routes that ride on that host: the arena's requests are
  on the arena's belt and inside bobbby.online's.
- `internet` gains `"clients"`:
  `{"classes": {"browser": 310, "bot": 122, "tool": 60, "other": 20}, "countries": [{"code": "US", "count": 300}], "window_s": 300}`,
  at most 8 countries, `""` reported as `"??"`. `tool` is a User-Agent
  starting `obs-factor-traffic` or `curl/` or `Wget/`; `bot` one containing
  `bot`, `spider`, `crawl` or `slurp` (any case) or empty; `browser` one
  starting `Mozilla/` that is neither; the rest `other`.
- The proxy's facts say lines read, `bad_lines`, `skipped_bytes`, rotations
  and `unrouted` requests over the window.
- History: `p95_ms` ("p95", ms) for nodes with requests in the log; `rps`
  for nodes with only `via`.

*(backend, 2026-11-19, sharpening the above)*: a tick that saw a rotation or
skipped bytes reports `via_rps`, `via_codes` and the belt rate as `null` (the
count is known short) while the tables still update. After one read the
source is ok, so a via-only belt is already `metered: true` with `rate:
null`. A line must carry `request.host`, `request.uri`, an integer `status`,
a numeric `duration` and string `ua` and `country`, else it is a bad line (a
default-format Caddy line is one). A country that is not two letters or
digits is `"??"`. Hosts match without regard to case, paths with; a pattern
without `*` is exact. `tool` is checked before `bot`. Traffic on a path route
counts as activity for a node's status. Percentiles come from a log-scale
histogram, 8 buckets per octave: within 4.4% of the exact sample. A line
longer than 1 MiB without a newline is dropped into `skipped_bytes`. Two
rotations the tail cannot see: a file truncated and regrown past the old
offset between two reads, and one recreated on the same inode.

## Reports: what is inside a building *(agreed 2026-11-19)*

Docker, Caddy and Postgres see a sub-app from outside. A **report** is what
the sub-app says about its own inside, in one shape for every runtime, so
the observer and the browser never learn what Phoenix is. The first reporter
is `packages/factory_report` (Elixir: the BEAM and every LiveView). A Node
relay or the Blimp server reports by serving the same JSON.

### The report (`GET <report url>` → 200 `application/json`)

```json
{
  "factory_report": 1,
  "app": "blog",
  "at": "2026-11-19T07:40:00Z",
  "runtime": {
    "kind": "beam",
    "versions": {"otp": "28", "elixir": "1.19.5", "phoenix": "1.7.19", "phoenix_live_view": "1.0.3", "app": "0.1.0"},
    "uptime_s": 12345,
    "gauges": {"memory.total": 123456789, "process.count": 812, "run_queue": 0},
    "counters": {"reductions": 99887766, "io.out_bytes": 123456}
  },
  "units": [
    {"kind": "liveview", "name": "BlogWeb.PostLive", "route": "/post/:slug", "count": 3,
     "gauges": {"memory": 812345, "message_queue": 0},
     "members": [{"id": "9f2c1a", "label": "/post/the-factory-must-grow", "since": "2026-11-19T07:31:02Z",
                  "gauges": {"memory": 301234, "message_queue": 0}, "counters": {"events": 14}}]}
  ],
  "streams": [
    {"kind": "liveview.event", "name": "BlogWeb.PostLive#like", "count": 120, "errors": 0, "duration_us": 1234567},
    {"kind": "http.route", "name": "GET /post/:slug", "count": 4410, "errors": 2, "duration_us": 98765432},
    {"kind": "db.query", "name": "Blog.Repo", "count": 99120, "errors": 0, "duration_us": 55443322},
    {"kind": "outbound.http", "name": "api.deepseek.com", "count": 41, "errors": 1, "duration_us": 81234567}
  ],
  "truncated": {"units": 0, "members": 0, "streams": 0}
}
```

Three ideas, and nothing else:

- **`runtime`**: the machine room. `gauges` are values now (`"dotted.key":
  number`); `counters` only ever grow while the process lives. Keys are open:
  the observer shows what it is given. A unit of measure is in the key's
  suffix by convention: `memory.*` and `*_bytes` are bytes, the rest counts.
- **`units`**: long-lived things that exist inside right now, grouped by
  `kind` + `name`: a LiveView page with its live sessions as `members`, a
  channel topic, a game room, a websocket client. `count` is how many
  members exist; `members` lists at most 20 of them (largest first by the
  first gauge); `gauges` on the unit are sums over all members. `label` is
  what a person would call the member (a LiveView's path, without query).
  `id` is opaque and stable while the member lives.
- **`streams`**: things that happen. One row per `kind` + `name`, cumulative
  since the process started: `count`, `errors`, and `duration_us` (the sum).
  The observer makes rates and averages from two reads, exactly as it does
  with Caddy's counters. `kind` is open; the ones the Elixir reporter emits
  are `http.route`, `liveview.mount`, `liveview.event`, `liveview.params`,
  `channel.join`, `channel.event`, `db.query`, `outbound.http`, and `custom`
  for what an app reports itself (`FactoryReport.event("gif.rendered", ...)`).
- Bounds are the reporter's job: at most 100 units, 20 members per unit, 300
  streams (the busiest by `count`), names cut at 120 characters. What was
  cut is counted in `truncated`. No request parameters, no assigns, no
  session data, no user identifiers, no query strings: names and numbers.
- `factory_report` is the format version. A number the observer does not
  know fails that node's report with the number.
- If the reporter was given a token (`FACTORY_REPORT_TOKEN`), the request
  must carry `authorization: Bearer <token>`; otherwise 401.

### The observer

- Topology: a node may have `report: "http://app:9568/report"` (an http(s)
  URL, like `probe`). `REPORT_TOKEN` (env) is sent as the bearer token to
  every report URL when set.
- An eighth source, `reports`: every tick, each report URL is read (2 s
  timeout, in parallel). The source is ok when the round ran; one node's
  failure is that node's, not the source's.
- Each node gains `"inside"`: `null` when it has no `report` URL, else

```json
{"ok": true, "error": null, "at": "2026-11-19T07:40:00Z",
 "runtime": {"kind": "beam", "versions": {}, "uptime_s": 12345,
             "gauges": {"memory.total": 123456789},
             "rates": {"reductions": 51234.5}},
 "units": [ ...as reported... ],
 "streams": [{"kind": "http.route", "name": "GET /post/:slug", "count": 4410,
              "rate": 1.2, "err_rate": 0.0, "avg_ms": 22.4}],
 "truncated": {"units": 0, "members": 0, "streams": 0}}
```

  `rates` (per second, one per counter), `rate`, `err_rate` and `avg_ms` are
  `null` until two reads of the same process exist; a smaller `uptime_s` or
  any counter going backwards is a restart and nulls that tick's rates.
  `avg_ms` is `null` when nothing happened in the tick. Streams are ordered
  busiest first by `rate` (then `count`) and cut at 40. When the read fails:
  `{"ok": false, "error": "...", "at": <last good or null>}` and every other
  key `null`.
- A node whose report fails gets an `attention` entry, severity `warn`
  (`"Phoenix blog report failing: connection refused"`). It does not change
  the node's status: the app may be fine and merely not reporting.
- These four series live in the 1 h store only (`res=5s`); they are never
  written to the 24 h store. *(2026-11-19)*
- History, per node with a report: `beam_memory` (`memory.total`), 
  `process_count` (`process.count`), `run_queue`, and `units` (the sum of
  unit counts), where those gauges exist.

### Reports, second round: who did it, and what was logged *(agreed 2026-11-19)*

- **`by` on a stream.** A stream row may carry `"by": {"kind": "liveview",
  "name": "BlogWeb.PostLive"}` (or `{"kind": "http.route", "name": "GET /cases"}`):
  the unit or route whose process caused it. Rows with `by` are a breakdown;
  the row with the same `kind` + `name` and no `by` stays and is the total,
  so nothing is counted twice by reading only rows without `by`. A reporter
  attributes what it can (the Elixir one: `db.query`, `outbound.http`,
  `custom` and `log`, from the process that made the call, or its caller for
  a task) and leaves the rest in the total alone. Breakdown rows count
  towards the 300-stream bound; the totals are kept first.
- **`log` streams.** `kind: "log"`, `name` the level (`"error"`,
  `"warning"`, ...): how many log events of that level, cumulative.
  `duration_us` is 0.
- **`events`.** The report gains `"events"`: the most recent notable things,
  newest first, at most 50:
  `{"at": "2026-11-19T08:40:02Z", "level": "error", "name": "Blog.GitHub.WorkLogPoller", "message": "poll failed: timeout", "by": {"kind": "liveview", "name": "..."} | null}`.
  The Elixir reporter records log events at `warning` and above; `name` is
  the module that logged; `message` is cut at 300 characters. Messages are
  the app's own words and can contain anything the app logs: the factory is
  behind its password, and the reporter never adds request parameters or
  session data itself.
- **The observer** passes `by` through on stream rows (`null` when absent)
  and adds `"events"` to `inside` (as reported, at most 50, strings cut;
  `[]` when the reporter sends none, `null` with a failing report). Stream
  rows with `by` get rates like any other. The 40-row cut keeps totals
  first.
- **Structured stdout** is separate from the report: the Elixir package ships
  a JSON formatter an app can give its default logger handler, one object
  per line (`time`, `level`, `msg`, `app`, `module`, `request_id`, `page`).
  Nothing reads those lines yet; they are for `docker logs` and for a later
  log source.

## Observer: a building's BEAM, live *(2026-11-22)*

`:observer` for one VM, as JSON, in two layers: the **engine** in
`packages/factory_report` (`FactoryReport.Observer`), served by each app on
its report port under `/observer/...`, and the **pass-through** on the
observer, `/api/nodes/:id/observer/*path`, which is how the floor reaches it.
Sub-apps are separate Erlang clusters, never connected to the observer: it
reaches them over HTTP only.

The page reads it over the bus, not over HTTP: one feed per topic
`observer:<node_id>:<member or ->:<view>` calls `ObsFactor.ObserverProxy.call/5`
on its interval and broadcasts what it returns, and actions are channel
pushes on those topics ("On the bus" below). The HTTP pass-through stays for
scripts and anything outside the page. The engine shapes below are what the
feeds carry as `data`.

### Engine: `<report base>/observer/...` (each app's report port)

Nothing runs until asked: no process, table or handler of its own.
`FactoryReport.Observer.dispatch(method, path, params, opts)` is the same
without HTTP. A pid is written `0.123.0` (`FactoryReport.Observer.pid_text/1`);
a pid of another node is refused (400). Every answer is a JSON object with
`"took_ms"` and `"node"` (`node()` as a string), errors included:
`{"error": "...", "node": ..., "took_ms": ...}`; the errors the plug answers
itself (auth, off switch, body) carry `"took_ms": 0.0`.

Auth. Reads need the report's token when the app was given one
(`FACTORY_REPORT_TOKEN`, `authorization: Bearer <token>`, else 401
`{"error": "unauthorized"}`). With no token, reads answer 403
`observer reads need a token: set the reporter's token (or
FACTORY_REPORT_TOKEN), or observer: true to serve them without one`, unless
the app passed `observer: true` explicitly (the lab's apps do). Actions are
off (403 `{"error": "actions are off: no actions_token configured", "path":
...}`) unless the app sets `actions_token:` / `FACTORY_REPORT_ACTIONS_TOKEN`;
then they take only `authorization: Bearer <actions_token>` (constant-time
compare, else 401 `unauthorized: actions need authorization: Bearer
<actions_token>`). A body that is not a JSON object is 400, one over 8 kB
413.
Every action is logged by the app at `warning`:
`factory_report observer action: kill 0.238.0 (:engine_throwaway) by <x-factory-by>`.
`observer: false` turns `/observer` off (404).

Reads (GET):

| Path | Params | Answer (besides `node`, `took_ms`) |
|---|---|---|
| `` (index) | | `{"observer": 1, "reads": [...], "actions": [...], "inspect_state": false}` |
| `system` | | `otp_release`, `erts_version`, `elixir`, `system_version`, `uptime_s`, `system_info`, `schedulers` `{online,total,dirty_cpu,dirty_cpu_online,dirty_io}`, `limits` `{process,port,atom,ets: {count,limit}}`, `memory` (`:erlang.memory`, bytes), `statistics` `{reductions,run_queue,run_queue_all,context_switches,gc_count,gc_words_reclaimed,io_in_bytes,io_out_bytes}`, `allocators` `[{name,blocks_bytes,carriers_bytes}]`, `distribution` `{alive,node,connected,net_ticktime_s}`, `logger` `{primary_level}` |
| `apps` | | `{"count": n, "apps": [{"name","vsn","description","top_supervisor": pid or null,"error"}]}` (at most 200) |
| `tree/:app` | `depth` 1..12 (8) | `{"app","supervisor","tree": node,"nodes","depth_limit","children_limit": 25,"node_limit": 1500,"time_limit_ms": 2000,"cut": {"depth","grouped","nodes","time","errors"}}` |
| `procs` | `sort` = `reductions` (default) \| `memory` \| `message_queue_len`; `limit` 1..200 (50); `interval_ms` 0..2000 (0; > 0 only with `sort=reductions`: two samples, ranked by reductions between them) | `{"sort","limit","interval_ms","total","walked","walk_limit": 100000,"procs": [summary]}` |
| `proc/:pid` | `state=true` (only if the app set `inspect_state: true`) | summary plus `application`, `links` `[{"pid"} \| {"port"}]`, `links_count`, `monitors`, `monitors_count`, `monitored_by`, `monitored_by_count`, `current_stacktrace` `[{"mfa","file","line"}]` (30), `dictionary_keys` (names only, 100), `dictionary_count` (both `null`, with `dictionary_not_read` saying why, when the process holds more than 1 MiB: listing keys copies every value), `heap_size_words`, `total_heap_size_words`, `stack_size_words`, `garbage_collection`, `trap_exit`, `group_leader`, `priority`, `supervisor_path`, `state` (`{"status": "not requested"}` unless asked and allowed) |
| `ets` | | `{"count","limit": 500,"cut","tables": [{"id","name","named","type","protection","size","memory_bytes","owner","owner_name"}]}` by memory |
| `ports` | | `{"count","limit": 500,"cut","ports": [{"id","name","os_pid","connected","input_bytes","output_bytes"}]}` by traffic |

A process summary: `{"pid","registered_name","current_function","initial_call","status","message_queue_len","memory","reductions","links"}`;
in a `procs` answer with `interval_ms` > 0 each one also carries
`reductions_delta` (reductions between the two samples) and
`reductions_per_s` (that, per second, rounded); with `interval_ms` 0 neither
key is there.
A tree node is a summary plus `{"id" (inspect of the child id),"type": "worker"|"supervisor"}`;
only a supervisor also has `"children": [node] | null` and
`"not_walked": null | "depth limit 2" | ...` (a worker has neither key);
a child that is not running is `{"id","type","pid": null,"status","restart","children": null,"not_walked": null}`
with `restart` `"permanent"|"transient"|"temporary"|null` (from the supervisor's child spec; null
for a DynamicSupervisor or no answer) and `status` `"restarting"`, `"finished"` (a transient or
temporary child that ran and stopped, e.g. a boot-time Task: not a fault) or `"not running"` (a
permanent child with no process, or restart unknown); a supervisor child that
died while it was walked is `{"id","type","pid","status": "dead","children": null,"not_walked": null}`;
children past 25 per supervisor are one `{"group": true,"count","memory","message_queue_len_max"}`.
`which_children` is sent only to processes proc_lib started as supervisors,
1 s timeout each. Strings are cut at 200 characters, lists at 100. Message
contents and dictionary values never leave the VM.

Example, `GET /observer/procs?sort=memory&limit=1`:

```json
{"interval_ms": 0, "limit": 1, "sort": "memory", "total": 545, "walked": 545, "walk_limit": 100000,
 "procs": [{"pid": "0.50.0", "registered_name": ":code_server", "current_function": ":code_server.loop/1",
            "initial_call": ":erlang.apply/2", "status": "waiting", "message_queue_len": 0,
            "memory": 2547256, "reductions": 982581, "links": 1}],
 "node": "nonode@nohost", "took_ms": 1.8}
```

Actions (POST, JSON body):

| Path | Body | Answer |
|---|---|---|
| `proc/:pid/kill` | | `{"ok": true,"action": "kill","pid","alive_after","exit_reason"}` |
| `proc/:pid/exit` | `{"reason": "shutdown"\|"normal"\|"kill"}` | `{"ok": true,"action": "exit","reason","pid","alive_after","exit_reason"?}` |
| `proc/:pid/gc` | | `{"ok": true,"action": "gc","pid","memory_before","memory_after"}` |
| `tree/:app/restart` | `{"supervisor": "0.1.0","child_id": "MyApp.Worker"}` (`inspect` of the id, as the tree shows it) | `{"ok": true,"action": "restart","supervisor","child_id","old_pid","new_pid"}` |
| `logger/level` | `{"level": "all"\|"debug"\|...\|"none"}` | `{"ok": true,"action": "logger_level","before","level"}` |

Example: `POST /observer/proc/0.238.0/kill` →
`{"ok": true, "action": "kill", "pid": "0.238.0", "alive_after": false, "exit_reason": ":killed", "node": "engineup@host", "took_ms": 0.09}`.

Engine errors: 400 bad parameter or pid (`not a pid: "nope" (expected the
form 0.123.0)`, `pid 4.1.0 is not on this node (...)`, `sort must be one
of ...`, `reason must be one of shutdown, normal, kill`, `... is not a
supervisor`); 404 no such endpoint, application, process (`no process
0.238.0 (not alive)`) or child; 405 the wrong method (`GET is not allowed on
/observer/proc/0.1.0/kill; use POST`); 409 refused, for kill and exit: the
answering process, `init` (`refused: 0.0.0 is init; killing it stops the
VM`), the VM's own processes by name (`application_controller`,
`erl_prim_loader`, `erts_code_purger`, `socket_registry`, `logger`, `user`,
`standard_error`, `code_server`, `file_server_2`, `kernel_sup`, `user_drv`),
anything whose group leader is init (started by erts before any
application), any `kernel` or `stdlib` process, and any application master;
for restart: anything in `kernel`'s or `stdlib`'s tree, a supervisor or a
child the kill rule refuses, a `:temporary` child (terminating it deletes
it, so it could not be restarted), and a DynamicSupervisor's child by id; 500/504 `terminate_child` or
`restart_child` failed or did not answer in 4500 ms, or a tree walk timed out.

### Pass-through: `GET|POST /api/nodes/:id/observer/*path[?member=<address>]`

Behind the session like the rest of `/api` (401 `{"error": "unauthorized"}`
without it). `*path` is the engine path above; query parameters other than
`member` are passed on for GET, the JSON body for POST.

- **`id = "observer"`**: the observer's own VM, answered in-process by
  `FactoryReport.Observer.dispatch/4` (no HTTP, no reporter started). The
  index (`GET /api/nodes/observer/observer`) also carries
  `"proxy": {"actions": true|false}` (whether `OBSERVER_ACTIONS_TOKEN` is
  set). `member=` is refused (400 `the observer is one VM: member= does not
  apply to node observer`). Actions are 403 `actions are off:
  OBSERVER_ACTIONS_TOKEN is not set on the observer` when it is unset.
- **any topology node with a `report` URL**: forwarded to the `/observer`
  beside that report: same scheme, host, port and mount path, a trailing
  `/report` replaced by `/observer` (`http://app:9568/report` →
  `http://app:9568/observer/<path>`). Reads send `REPORT_TOKEN` as the bearer
  token; actions send `OBSERVER_ACTIONS_TOKEN`, `content-type:
  application/json` and `x-factory-by: <by>`. The upstream's status and JSON
  body come back as they are (its 401, 403, 404, 409 ...).
- **`member=<address>`** picks one member of a clustered node: the request
  goes to that address instead of the report URL's host. The address must be
  one of the node's members as the reports collector read them last (the
  `address` of each `inside.members[]` entry). A node with several members
  needs it.

Who acts: a POST must say who, as the `x-factory-by` header or `"by"` in the
body (the header wins; non-printing characters removed, cut at 80); else
400. `"by"` is not forwarded in the body.

Limits: path segments match `[A-Za-z0-9_.-]{1,200}`; reads time out after
3 s, actions after 5 s; an upstream body over 4 MiB is refused (502).

Errors (all `{"error": "..."}`, status as given):

| Status | When | Example |
|---|---|---|
| 400 | bad path segment | `bad path segment "a b"` |
| 400 | POST without who | `say who is acting: an x-factory-by header or "by" in the body` |
| 400 | member not current | `"10.9.9.9" is not one of app's current members (10.0.0.5, 10.0.0.6)` |
| 400 | member on a single node | `app is one node, not a cluster: member= does not apply` |
| 400 | clustered node, no member | `app has 2 members: say which with member= (10.0.0.5, 10.0.0.6)` |
| 400 | members unknown | `app's members are not known: reports source: ...` |
| 403 | actions off here | `actions are off: OBSERVER_ACTIONS_TOKEN is not set on the observer` |
| 404 | no such node | `no node "nope" in the topology` |
| 404 | node without a report | `node caddy has no report URL, so no observer` |
| 502 | upstream unreachable | `{"error": "127.0.0.1:19568: connection refused", "upstream_status": null}` |
| upstream's | upstream answered non-JSON | `{"error": "app:9568 answered 404: not found (a factory_report without the observer?)", "upstream_status": 404}` |

Every POST, done or refused, is recorded twice on the observer:

- one `warning` log line (LogRing, so `/api/beam` and `/api/logs`), event
  `action.done` or `action.refused` with `source: "actions"`, `node`,
  `member`, `action`, `target`, `args`, `by`, `status`, `took_ms`, `error`
  (see "Logs" below; `node_id` before 2026-11-23):
  `action proc/0.238.0/kill on upvm by engine-agent: ok`,
  `action proc/0.1.0/exit reason="shutdown" on app (10.0.0.5) by carol: 403: actions are off: ...`;
- one message on `ObsFactor.PubSub` topic `"actions"`
  (`ObsFactor.ObserverProxy.actions_topic/0`), so every viewer sees what
  anyone did:

```elixir
{:action,
 %{"at" => "2026-11-22T23:12:36.050Z", "node" => "upvm", "member" => nil,
   "path" => "proc/0.238.0/kill", "params" => %{}, "by" => "engine-agent",
   "status" => 200,
   "result" => %{"ok" => true, "action" => "kill", "pid" => "0.238.0", "alive_after" => false, ...},
   "error" => nil}}
```

  `member` is `nil` unless given; `params` holds only `reason`,
  `supervisor`, `child_id`, `level`; `by` is `nil` when nobody said (that
  request was refused); a `by` that is blank once non-printing characters
  are removed and it is trimmed counts as nobody said; exactly one of
  `result` (the 2xx body) and `error` (the message) is non-nil. Reads are
  not broadcast. A channel `action` push the channel refuses itself (no
  `path`, `params` not an object) is recorded the same way, with `path`
  `""` when it gave none and `params` `%{}` when they were not an object.

`POST /api/builds` is recorded the same way: `node` `"builder"`, `path`
`"builds"`, `params` the job's `name`, `mode`, `repo`, `ref`, `label`,
`by` from `x-factory-by` or `"by"` in the body (`nil` when nobody said; a
build does not need a name), `result` the builder's 2xx body or `error`
its refusal (404 no builder, 502 unreachable, the builder's 4xx).

### On the bus: `observer:<node_id>:<member or ->:<view>` *(2026-11-22)*

`ObsFactor.Feeds.ObserverViews` (listed in `config :obs_factor, :feed_views`)
serves every `observer:*` topic but `observer:observer:-:beam` (the built-in
"Under the hood" feed). One feed per topic, however many browsers watch it;
each fetch is `ObsFactor.ObserverProxy.call("GET", node, path, params, member: member)`,
so in-process for node `observer` and over HTTP (with `REPORT_TOKEN`, 3 s
timeout, 4 MiB cap) for a building.

- `<node_id>`: `observer` or a topology node with a `report` URL.
- `<member>`: `-` for the observer and for a single node; for a clustered
  node, one `address` of its `inside.members[]` (the reports collector's
  last read, which is what the snapshot shows). IPv4 addresses and names
  only (`[A-Za-z0-9_.-]`).
- `<view>`:

| view | engine read | every |
|---|---|---|
| `system` | `system` | 5 s |
| `apps` | `apps` | 5 s |
| `tree:<app>` | `tree/<app>` (depth 8) | 2 s |
| `procs:reductions` | `procs?sort=reductions&limit=50&interval_ms=1000`: ranked by reductions within one second, so a feed shows who is busy now, not who has run longest; the fetch takes ≥ 1 s | 2 s |
| `procs:memory`, `procs:message_queue_len` | `procs?sort=<sort>&limit=50` | 2 s |
| `proc:<pid>` | `proc/<pid>` (`0.123.0`) | 1 s |
| `ets` | `ets` | 5 s |
| `ports` | `ports` | 5 s |

Intervals per view: `config :obs_factor, :observer_feed_intervals_ms, %{"proc" => 2_000}`
(keys `system apps tree procs proc ets ports`).

**Join.** Checked with the pass-through's own checks
(`ObsFactor.ObserverProxy.check_target/2`), no request made. Reply: the
feed's last payload, or `{}` before its first fetch. Refused with
`{reason}`, the same text the HTTP pass-through gives:

| topic | reason |
|---|---|
| `observer:nope:-:system` | `no node "nope" in the topology` |
| `observer:caddy:-:system` | `node caddy has no report URL, so no observer` |
| `observer:observer:10.0.0.1:system` | `the observer is one VM: member= does not apply to node observer` |
| `observer:app:-:system`, app clustered | `app has 2 members: say which with member= (10.0.0.5, 10.0.0.6)` |
| `observer:app:10.9.9.9:system` | `"10.9.9.9" is not one of app's current members (10.0.0.5, 10.0.0.6)` |
| `observer:app:10.0.0.5:system`, app single | `app is one node, not a cluster: member= does not apply` |
| `observer:observer:-:flame` | `no observer view "flame": one of system \| apps \| tree:<app> \| procs:<reductions\|memory\|message_queue_len> \| proc:<pid> \| ets \| ports` |
| `observer:observer:-:procs:age` | `procs:<sort> sorts by reductions, memory, message_queue_len, not "age"` |
| `observer:observer:-:proc:self` | `proc:<pid> needs a pid written 0.123.0, got "self"` |
| `observer:observer:-:tree:Bad` | `tree:<app> needs an application name, got "Bad"` |
| `observer:x` | `observer topics are observer:<node id>:<member address or ->:<view>, got "observer:x"` |

**Pushes.** `feed` with `{at, data}`, `data` the engine's 200 answer as is
(with `node` and `took_ms`), or `{at, error}`: every other answer, as
`<node> [(<member>)] /observer/<path> answered <status>: <error>`, e.g.
`observer /observer/proc/0.999.0 answered 404: no process 0.999.0 (not alive)`,
`app /observer/ets answered 502: 127.0.0.1:19568: connection refused`; a 200
without `node` is `app answered 200 without "node", not an observer engine
answer: ...`. A member that left the cluster after the join is an error on
every fetch, not a closed channel.

**Actions.** Push `action` on any `observer:<node>:<member>:*` topic you have
joined (the observer's `beam` topic included):

```js
await bus.push("observer:observer:-:tree:obs_factor", "action",
  { path: "proc/0.284.0/gc", params: {}, by: "dave (floor)" });
// → {"ok": true, "action": "gc", "pid": "0.284.0", "memory_before": 2864, "memory_after": 2864, "node": ..., "took_ms": 0.04}
```

`path` is an engine action path, `params` its JSON body (`reason`,
`supervisor`/`child_id`, `level`; `by` in it is dropped), `by` who is acting
(required; non-printing characters removed, cut at 80). Node and member are
the topic's. It is exactly `POST /api/nodes/:id/observer/<path>[?member=]`:
forwarded with `OBSERVER_ACTIONS_TOKEN`, `content-type: application/json`
and `x-factory-by: <by>`, logged (LogRing warning, `source: "actions"`) and
broadcast as `{:action, map}` on `actions`, done or refused. The reply is the
engine's 2xx body, else `{error, status}` (bus.js rejects with `Error(error)`):
`{error: "actions are off: OBSERVER_ACTIONS_TOKEN is not set on the observer", status: 403}`,
`{error: "say who is acting: ...", status: 400}`,
`{error: "action needs {path, params, by}, ...", status: 400}`. Any other event
is `{error: "\"x\" is not an event of <topic>"}`.

After an action that answered 2xx, 500 or 504 (by push or by POST), every
running feed of that node and member (`observer:<node>:<member>:`, from
`ObserverProxy.topic_prefix/2`) is refetched at once, so the tree, the procs
and the process show the effect without waiting for their period.


### The Processes panel and the lenses *(2026-11-22)*

The page's `processes.js` reads only the bus. Sources: every node of the
snapshot with `inside` non-null, one per `inside.members[].address` when
there are two or more, else member `-`; and `observer` (not on the floor).
Topics: `observer:<node>:<member>:procs:<memory|message_queue_len|reductions>`
per source in scope, `observer:<node>:<member>:proc:<pid>` for the open
process, `actions` while the panel is open, `snapshots` to follow the
floor's sources. Reductions/s is the engine's `reductions_per_s` on the
`reductions` feed, and otherwise the difference between two reads of the
same pid over their `at`s (`-` until there are two). Actions: `action`
`{path: "proc/<pid>/<gc|exit|kill>", params: {} | {reason: "shutdown"}, by:
"<name> (processes)"}` on the process's topic, after a confirm that names
the pid, its name and the node/member; the name is localStorage
`obs_factor.who` (the one Missions signs with), asked for when empty.

Lens owner (`main.js`): `lens.claim(owner, {map, label, detail, onDrop})`,
`lens.drop(owner)`, `lens.owner()`. `map` is what `Scene.focus` takes (node
id → `"alert" | "warn"`); inside a building it goes on the floor underneath.
One owner at a time: a claim calls the previous owner's `onDrop`. Owners:
`missions` (issues lens) and `processes` (metric lens: the worst process of
each building, from `procs:<metric>` of every reporting source; amber/red at
mailbox 100/1000, memory 50/200 MiB, reductions 500k/2M per second).

The jump list (`jump.js`, Cmd/Ctrl+K) joins `objectives` while it is open.

