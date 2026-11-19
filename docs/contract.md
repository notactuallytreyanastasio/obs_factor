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
