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
| `REPORT_TOKEN` | optional bearer token sent to every `report` URL (Reports) | |

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
