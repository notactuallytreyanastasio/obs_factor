# obs_factor

A live view of the bobbby.online box drawn as a factory. One Phoenix service
(no Ecto) runs as one more container in the blog stack's Docker Compose and
watches the rest of it: the ~18 containers behind Caddy, their shared
Postgres, the static sites Caddy serves from `/srv/*`, and the host's CPU,
memory and disk. Every 5 s it reads Docker, Caddy's Prometheus metrics,
`pg_stat_database`, `/proc` and `statfs`, and probes each app over HTTP. The
browser draws the snapshot. Nothing is simulated: a source that cannot be
read is shown as failing and the numbers it would have given are unknown.

The interface between the observer, the browser and this wiring is
[`docs/contract.md`](docs/contract.md).

| path | what |
|---|---|
| `lib/`, `config/` | the observer (Elixir) |
| `priv/static/` | the factory (browser) |
| `priv/topology/prod.exs`, `lab.exs` | names, places and wires what Docker reports |
| `lab/` | the production stack in miniature, to run the observer against for real |
| `Dockerfile`, `.dockerignore` | the release image |
| `deploy/` | what production needs, as files a human applies |
| `deploy.sh` | ships the source to the box and rebuilds the service |

## Setting up on another machine

To work on it (laptop):

```bash
git clone git@github.com:notactuallytreyanastasio/obs_factor.git && cd obs_factor
mix deps.get && mix test          # Elixir 1.18+ / OTP 27+; no database, no node, no asset build
```

Then one of three ways to see it, cheapest first:

1. **Frontend only, from fixtures** (needs Node 20+, nothing else):
   `node scripts/dev-static.mjs --fixture bad-day`, open
   http://localhost:4010, password `dev`.
2. **The whole thing against the lab** (needs Docker): the commands under
   "The lab" below, then http://localhost:14000, password `obslab`. With
   Colima the checkout must be under `$HOME` (it mounts nothing else), and
   if only the standalone binary is installed, spell it `docker-compose`.
3. **`mix phx.server` against the lab**: "Running `mix phx.server` on the
   laptop instead", below. On macOS the host source fails (no `/proc`) and
   says so.

To deploy from that machine, `./deploy.sh` needs `ssh root@5.161.181.91`
to work without a prompt, and `rsync`. It runs the suite, syncs the tree to
`/opt/obs_factor`, checks the wiring, rebuilds `obs-factor` and checks
`https://factory.bobbby.online/health`. Nothing else is needed locally:
the secrets live in `/opt/blog/.env` on the box. The login password is
`OBS_FACTOR_PASSWORD` there:

```bash
ssh root@5.161.181.91 "grep '^OBS_FACTOR_PASSWORD=' /opt/blog/.env"
```

To change what the box runs around it (the compose services, the Caddy
site), edit `~/code/blog` and ship with that repo's `deploy.sh`; see
"Production wiring".

To stand it up on a different server, that server needs Docker Compose,
Caddy 2.10.x and (optionally) Postgres in one compose project. Then:

1. Write a topology for it, starting from `priv/topology/lab.exs`
   (`docs/contract.md` has the format; containers you do not list still
   show up, on the "unplaced" pad), and point `TOPOLOGY` at it.
2. Add the two services and the network from
   `deploy/compose.obs-factor.yml` to its compose file, changing
   `PHX_HOST`, the site mounts and the build context.
3. Apply the three Caddyfile pieces in `deploy/Caddyfile.patch`:
   `metrics { per_host }`, the `http://:9180` metrics site, and the
   reverse proxy site for your hostname.
4. Put the three keys from `deploy/env.example` in the stack's `.env`,
   run `deploy/postgres-role.sql`, `mkdir -p /var/lib/obs_factor/statfs`.
5. Point DNS at it, set `HOST`, `STACK_DIR` and `URL` at the top of
   `deploy.sh`, and run it.

## The lab

`lab/compose.yml` (project `obslab`) is the box's shape on a laptop: real
Docker, real Caddy 2.10.2 metrics, real Postgres 17.

| service | stands in for | notes |
|---|---|---|
| `caddy` | caddy | 2.10.2, `metrics { per_host }`, `http://:9180 { metrics }`, the same `servers { protocols h1 h2 }` block |
| `blog` | blimp-blog | `traefik/whoami`, hosts `blog.lab.test` and `www.blog.lab.test`, database `lab_blog` |
| `links` | blinks | whoami, `links.lab.test`, database `lab_links` |
| `arena` | soldat | whoami, path route `blog.lab.test/arena/*` |
| `relay` | skee-relay | `node:24-alpine`, bind-mounted, `mem_limit: 96m`, `relay.lab.test` |
| docs site | deciduous.dev | Caddy `file_server` from `lab/sites/docs`, `docs.lab.test` |
| `migrate` | temper-link | a one-shot that exited 0 |
| `db` | db | `postgres:17.11-alpine`, `max_connections=30`, the `obs_factor` monitoring role |
| `docker-proxy` | docker-proxy | the production allowlist, `deploy/docker-proxy/Caddyfile` |
| `observer` | obs-factor | profile `observer`: the release image from `./Dockerfile` |

```bash
docker compose -f lab/compose.yml up -d            # or docker-compose -f ...
lab/load.sh -r 20 -d 300                            # 20 req/s across the hosts for 5 min
lab/db-busy.sh lab_links 2 300                      # pgbench: ~50 commits/s for 5 min

# the observer, as production runs it (release image, real container /proc):
docker compose -f lab/compose.yml --profile observer up -d --build observer
open http://localhost:14000                          # password: obslab

docker compose -f lab/compose.yml --profile observer down -v   # all gone, volumes too
```

Published ports, all on 127.0.0.1: Caddy 18080 (sites, by Host header:
`curl -H 'Host: blog.lab.test' localhost:18080/`), Caddy metrics 19180,
Postgres 15433, Docker proxy 12375, observer 14000. The observer is also
behind Caddy at `factory.lab.test`, with the production site block.

### Running `mix phx.server` on the laptop instead

Stop the observer container first (the `obs_factor` role allows one
connection), then:

```bash
PORT=14001 OBS_FACTOR_PASSWORD=obslab \
DOCKER_URL=http://127.0.0.1:12375 \
CADDY_METRICS_URL=http://127.0.0.1:19180/metrics \
PG_URL=postgres://obs_factor:obslab@127.0.0.1:15433/postgres \
HOST_PROC=/proc HOST_DISK_PATH=$PWD/lab/state/hostfs SITES_DIR=$PWD/lab/sites \
TOPOLOGY=priv/topology/lab.exs mix phx.server
```

Docker, Caddy, Postgres and sites read fine from there. Two things are
honestly broken, and the snapshot says so: macOS has no `/proc`, so the
`host` source fails (`cannot read /proc/stat: no such file or directory`)
and the three resource nodes are `unknown`; and the probes go to compose
service names that do not resolve outside the Docker network, so every
probed node is `down` with `probe failed: host not found`. For those, run
the container.

### Live: one socket

The page holds one websocket (`/socket`, Phoenix Channels) and everything
live comes over it: the floor (`snapshots`, one push per tick), Under the
hood (the feed `observer:observer:-:beam`), the log explorer (`logs`, each
event as it is logged), the inspector's history (`history:<node>:<res>`) and
build logs (`builds:<id>`), objectives and actions. On the server each of
those is a PubSub topic; data that has to be fetched (the observer's own
BEAM, a node's history, a build) is fetched by one process per topic
however many browsers watch, and stops 10 s after the last one leaves.
The page sends no request on a timer: after login its only `/api` request is
`GET /api/socket_token` (a 60 s token for the socket), again before each
reconnect. The top bar says `live`, `reconnecting` or `refused`, with the
reason on hover. Topics, payloads and how to add a feed:
docs/contract.md "Live: one socket".

A building's BEAM is on the same socket: `observer:<node>:<member or ->:<view>`
(view `system`, `apps`, `tree:<app>`, `procs:<sort>`, `proc:<pid>`, `ets`,
`ports`) is one feed per topic reading the app's `/observer/...` (or the
observer's own VM in-process) every 1 to 5 s. An `action` pushed on such a
topic (`{path: "proc/0.284.0/gc", by}`) goes to the app with
`OBSERVER_ACTIONS_TOKEN`, is broadcast on `actions` to every viewer, and
refetches that node's feeds at once. Checked in headless Chrome against
`mix phx.server` on the lab: `observer:observer:-:tree:obs_factor` pushed
every 2 s, a gc pushed on it was answered, came back on `actions`, and the
tree was pushed again 5 ms later. No page shows these feeds yet; the lab's
buildings report on Docker-network names, so only node `observer` was
checked from outside the container. docs/contract.md "Observer: a
building's BEAM, live", "On the bus".

Opening the page under a host name other than `PHX_HOST` (the lab at
`127.0.0.1` instead of `localhost`) needs `CHECK_ORIGIN`; without it the top
bar says `refused` and names what is allowed.

Checked in headless Chrome at 1440×900 against `mix phx.server` on the lab:
6 snapshot pushes in 30 s, the beam feed every 2 s while the panel was open
(one `phx_close` when it closed), 9 new log lines tailed from 3 requests made
during the test, history charts filled from the feed, and one `/api`
request in the whole session. With the server stopped the bar said
`reconnecting: observer unreachable (Failed to fetch)`; restarted with
`CHECK_ORIGIN=//localhost` it said `refused: the observer does not accept a
websocket from http://127.0.0.1:14201: CHECK_ORIGIN allows ["//localhost"]`;
restarted without, `live` again with no reload.

### The tour, and under the hood

**Tour** (bottom bar, or the ☰ menu on a phone, or `/?tour`) walks the
live page in 19 stops: the floor, the live clock, the attention strip, the
lamps, the sources, Caddy and its inspector, per-host rates, history, a
probe, a container, the sites list, a build's real log, then **Under the
hood**: the observer's own VM, its supervision tree with one collector per
source, the ETS tables the snapshot is built from, and its own log. Every
number a stop quotes is read at that stop. A stop whose subject isn't there
(no failing source, no built app, no probed container) is skipped, never
filled in.

Checked with headless Chrome against the lab at 1440×900 and 390×844, all
stops, no page errors; and once with `docker stop obslab-docker-proxy-1`,
where the tour finds the failing `Docker` collector and its log line
`source docker: host not found`.

**Log explorer.** Click any log on the page (the build log in the
inspector, the log in Under the hood) or ☰ → Logs. One list holds the
observer's own log (`service:observer`, tailed live over the socket) and
the whole job log of every build on the floor (`service:builder`). Builder lines are
program output with no level, so their level is `unset`, not a guess.

- Search: `level:error`, `-source:docker`, `"host not found"`, `/time(d)? out/`,
  `job:deci-*`, `level:(warning OR error)`, `a OR b`, `line:>100`, `request_id:*`.
  A broken query says what's wrong (`missing ) after level:(`).
- Facets (level, service, source, build, step, module, domain) with counts
  computed without their own filter, so they show what a change would give.
- A histogram stacked by level; drag across it to zoom into a time range,
  double-click to reset. Presets 5m to 1d, or all.
- Click a line for every attribute, each with + (only this) and − (exclude),
  and "±1 min around it" for context. `/` search, ↑↓ move, Esc close.

Checked in headless Chrome at desktop and phone sizes, no page errors.
Several of the queries above were run against the lab, including the regex
and the error message for a broken query; live tail picked up new lines.

Not there: container logs. They'd need `/containers/{id}/logs` through
`docker-proxy`, which allows three GET endpoints on purpose, and app logs
can carry secrets. The two logs the tour shows are the builder's job log
and the observer's own.

### Missions: what to check before you leave

The attention strip is recomputed every tick and forgets. **Missions** (top
bar, with the count of undone objectives, red when one is an alert) is the
part that remembers: every alert and warning the rules raise becomes an
objective in Postgres (`ObsFactor.Objectives`), kept until a person crosses
it off with a note. One that goes away by itself for a minute is *cleared*,
not done, and stays on the list as "cleared itself — check and cross off".

- **Go** flies to the building (leaving the inside of one first); an
  objective whose building is not in the current snapshot says so.
- **I'm on it** shows "looking — name" to everyone; **Cross off** asks for
  a note; **Reopen** undoes it. The name is asked once and kept in
  localStorage: there is one password, so it is a label, not an identity.
- **Flag** (in the inspector, or `f` with a building selected) pins an
  objective on a building by hand. Inside a building it pins the building.
- **Issues lens** (`l`): everything under a veil except the buildings with
  an undone objective. Inside a building it lights the floor underneath.
- **Before you leave**: still open, cleared but unchecked, and what you
  crossed off this session with your notes, and a plain-text handover to
  copy. Log out offers it when you crossed something off.

The panel is live over the page's one socket: the `objectives` channel's
join reply is the list, each change anyone makes arrives as an `objective`
push, and I'm on it / Cross off / Reopen / Flag are `act` and `pin` pushes
on the same channel. The list changes when the broadcast comes back, not
from the reply, so two browsers cross off in step. The debrief also lists
what came over the `actions` topic since the tab opened (empty until
something publishes there). No request is made on a timer; the one GET of
`/api/objectives` is a resync after the store was unreadable at join and a
change then arrived.

It needs `OBJECTIVES_PG_URL`, a database and role of its own
(`deploy/objectives-db.sql`, run as its header says). Unset, the Missions
control is hidden and `/api/objectives` answers 503 `no objectives store`;
set but unreachable, the control shows `!` and the panel the error. For
`mix phx.server` on the laptop:
`OBJECTIVES_PG_URL=postgres://postgres:postgres@localhost/obs_factor_dev`.

Checked in headless Chrome against a dev server at 1440×900 and 390×844 on
2026-11-22 with the Docker lab down, so the rule objectives were the failing
sources and the down apps, not cluster alerts. The inside-a-building path
was checked with a snapshot given a made-up inside, since no building had a
working report. `deploy.sh` does not check for this database: it is optional,
and its wiring check treats every key it knows as required.

### Building apps (prototype)

"Build new app" in the factory makes a new hostname and, optionally, an app
behind it, from primitives that each do one real thing and check it:

| step | primitive | checked by |
|---|---|---|
| `name` | A record `<name>.lab.test -> 127.0.0.1` in `lab/built/dns/hosts`, served by CoreDNS (`dns`) | asking that DNS server (over TCP) |
| `route` | `lab/built/caddy/<name>.caddy`, a placeholder page, `caddy reload` | GET through Caddy with that Host |
| `source` | `git clone --depth 1` of a `https://github.com/...` repo | the commit sha |
| `recipe` | a small agent (`ObsFactor.Builder.Agent`, DeepSeek over its chat completions API) reads the README and the code, and writes `.obs_factor/build.json` (and a Dockerfile if there is none) | the builder validates the plan |
| `image` | `docker build` | exit status |
| `service` | `docker run` on `obslab_default` with `obs_factor.*` labels, generated secrets via `--env-file` | still running after 8 s |
| `check` | the route becomes a `reverse_proxy` | the plan's health path answers through Caddy |

"Just the lot" stops after `route`: DNS and a placeholder page. The lot is
on the floor from the first step (a `construction` node on the "built here"
platform), with its steps, the agent's plan and the build log in the
inspector; once the container runs, it is an ordinary building.

The builder runs on the laptop, not in a container, because it needs Docker
write and git (in production that would make it root on the box). The
observer stays read-only and reaches it at `host.docker.internal:14100`.
The agent is any OpenAI-compatible chat completions API: `BUILDER_LLM_URL`,
`BUILDER_LLM_KEY`, `BUILDER_LLM_MODEL`. `lab/builder.sh` defaults to
`https://api.deepseek.com` and `deepseek-flash`, and takes the key from
`DEEPSEEK_API_KEY` in `~/code/blog/.env` (`BUILDER_ENV_FILE` to change it):

```bash
docker compose -f lab/compose.yml --profile observer up -d --build
lab/builder.sh                          # OBS_ROLE=builder on 127.0.0.1:14100
open http://localhost:14000             # "Build new app"
dig +tcp @127.0.0.1 -p 15353 deci.lab.test +short
curl -H 'Host: deci.lab.test' localhost:18080/
```

What it writes is under `lab/built/` (gitignored): `dns/hosts`, `caddy/`,
`jobs/<id>.json` and `.log`, `apps/<name>/src` (the clone) and
`apps/<name>/secrets.env` (mode 600).

The agent is a loop over `POST /chat/completions` with tools: send the
conversation, run the tool calls it asks for, append the results, repeat
until it answers without a tool call (40 turns at most). Its four tools are
confined to the clone: `list_files`, `read_file`, `grep`, and `write_file`,
which only writes under `.obs_factor/`. No shell, no network, no symlink is
followed. The repository's text still reaches the model, so a README can
steer what it writes: the builder validates the plan (paths stay inside the
clone, the port is a port, env names are env names) instead of trusting it.

Every turn resends the whole conversation, so the loop is built to keep
the conversation small. Tool results are capped (a `read_file` is 150 lines
by default and at most 12000 characters; the model pages and greps instead
of reading whole files). Past 24k prompt tokens, every tool result older
than the last two turns is replaced by a one-line stub, all in one batch, so
the prompt prefix stays the same between compactions and the provider's
prefix cache keeps hitting. The prompt asks for independent reads in the
same turn. Measured on deciduous with `deepseek-flash`, recipe step only:

| | turns | tool calls | prompt tokens (from cache) | completion | time |
|---|---|---|---|---|---|
| before | 21 | 37 | 621,563 (581,888) | 9,553 | 72 s |
| after, run 1 | 14 | 25 | 177,781 (148,992) | 5,837 | 44 s |
| after, run 2 | 11 | 19 | 165,915 (139,776) | 5,221 | 38 s |

All three plans were the same server (port 4141, the root Dockerfile, the
token as a secret, `/data` as a volume). The health path differed between
runs (`/health`, `/api/v1/health`); both are real routes (`src/api.rs`).

#### A records in Cloudflare

`BUILDER_DNS_PROVIDER=cloudflare` makes the name step write the A record
through Cloudflare's v4 API instead of the lab's hosts file. Same rules: the
record's `comment` carries `obs_factor name=<name> job=<id>`, the builder
only updates or deletes records carrying it, and any other record under the
name (A, AAAA, CNAME, TXT) fails the step with what it found.

```sh
BUILDER_DNS_PROVIDER=cloudflare
BUILDER_CF_API_TOKEN=...            # Zone > DNS > Edit, on this zone only
BUILDER_CF_ZONE_ID=...              # zone overview page, right column
BUILDER_CF_PROXIED=true             # match the other bobbby.online sites
BUILDER_DOMAIN=bobbby.online
BUILDER_A_RECORD=<the box's public IPv4>
BUILDER_DNS_SERVER=alberto.ns.cloudflare.com:53
BUILDER_SITE_PREFIX=                # empty: Caddy's automatic HTTPS
```

`BUILDER_DNS_SERVER` is the zone's own nameserver on purpose. A public
resolver that was asked for the name before it existed caches NXDOMAIN for
up to 30 minutes, and the step would wait on that cache instead of
Cloudflare. Checked on 2026-11-20: `alberto.ns.cloudflare.com` answers
over TCP (what `Name.lookup` uses) with the proxied addresses for
`factory.bobbby.online`, and with nothing for a name that does not exist.
With proxying on, the answer is Cloudflare's addresses, not the box's, so
the step accepts any A answer then.

Tested against an in-memory fake of the API (`test/obs_factor/builder_name_test.exs`:
create, update in place, refuse a foreign CNAME, delete only its own,
Cloudflare's error codes passed through). Not yet run against the real
zone: there is no API token on the laptop.

Not done: tearing an app down from the UI, a production home for the
builder (Docker write is root on the box; the lab's builder runs on the
laptop and reloads the lab's Caddy only).

### Breaking it on purpose

`lab/break.sh --help` lists everything. Each row was run against the
observer container and the snapshot read back (`/api/snapshot`):

| do | the observer showed |
|---|---|
| `lab/break.sh stop links` | links `down`, "exited (code 2)", alert |
| `lab/break.sh 5xx blog on` (whoami `/health` answers 500) | blog `down`, "probe failed: answered 500", alert |
| `lab/break.sh 5xx relay on` (relay answers 503) | relay `down`, "probe failed: answered 503"; `code="503"` in Caddy's series |
| `lab/break.sh crashloop on` | relay `down`, "restart loop (7 restarts in 15 min)", alert |
| `lab/break.sh eat 75` (of 96 MiB) | relay `blocked`, "memory at 96% of limit", warn "92 MB of 96 MB limit" |
| `lab/break.sh eat 200` | OOM kills; relay `down`, "restart loop (4 restarts in 15 min)" while the file stays |
| `lab/db-connections.sh 26` | db `blocked`, alert "Postgres at 28 of 30 connections" |
| `lab/break.sh source caddy down` | source `caddy` failing ("host not found"), caddy `down` |
| `lab/break.sh source docker down` | source `docker` failing ("host not found"); every container node `unknown`, "docker source failing" |
| nothing (`migrate` exited 0) | migrate `idle`, never `down` |
| `lab/break.sh reset` | all of the above undone |

What these runs taught, that the observer has to know:

- **Upstream 5xx is not an "error" to Caddy.** An app that answers 500 or 503
  appears only as `code="500"` on `caddy_http_request_duration_seconds_count{host=...}`;
  `caddy_http_request_errors_total` does not move. It moved only when the
  upstream was down and Caddy produced the 502 itself (3 of 3 requests).
- **Requests to a host with no site block are not counted** (`ghost.lab.test`
  in `load.sh`), and path routes count under the host they ride on
  (`/arena/*` is in `blog.lab.test`).
- **Caddy counts its own metrics scrapes** as `handler="metrics"` under the
  scrape's Host (`caddy:9180`), and plain-HTTP redirects under the site's
  host with `server="remaining_auto_https_redirects"`. The observer drops
  `handler="metrics"`.
- **`OOMKilled` is only true between the kill and the restart.** Polling
  inspect every 250 ms during `eat 200`: while `restarting`, `OOMKilled=true`
  and `ExitCode=137`; as soon as it runs again both reset and only
  `RestartCount` (4, 5, ... 10 in ten seconds) remembers.
- **`docker restart` resets `RestartCount` to 0.** Right after
  `lab/break.sh crashloop on` (which restarts the relay) the first image
  said "restart loop (0 restarts in 15 min)". The backend now sums rises
  between ticks; the rebuilt image says "restart loop (7 restarts in 15 min)"
  16 s into the same loop.
- A stopped compose service's name stops resolving, so its source error is
  "host not found", not "connection refused".
- The observer sees every container on the daemon. On a laptop that
  includes other projects' containers (they show as unplaced); on the box it
  is the blog stack.

## The Docker socket proxy

The raw Docker socket is root on the host: anything that can POST
`/containers/create` can start a privileged container with `/` mounted. The
observer needs three GETs, so the proxy (`deploy/docker-proxy/Caddyfile`, a
`caddy:2.10.2` container, used unchanged by the lab and by production)
forwards exactly those and answers 403 to everything else:

```
GET /containers/json            list
GET /containers/{id}/json       inspect
GET /containers/{id}/stats      stats
```

Proof, through the lab proxy (`P=http://127.0.0.1:12375`), trimmed:

```
GET    /containers/json?all=true                       -> 200  [{"Id":"d24ce30dcc6b71c6...
GET    /v1.47/containers/json                          -> 200
GET    /containers/obslab-blog-1/json                  -> 200  {"Id":"d24ce30dcc6b...
GET    /containers/d24ce30dcc6b.../stats?stream=false  -> 200  {"id":"d24ce30dcc6b...
--- writes
POST   /containers/create  {"Image":"alpine:3.22"}     -> 403  {"message":"refused by obs_factor docker-proxy"}
POST   /containers/obslab-blog-1/stop                  -> 403
POST   /containers/obslab-migrate-1/start              -> 403
POST   /containers/obslab-blog-1/restart               -> 403
POST   /containers/obslab-blog-1/kill                  -> 403
POST   /containers/obslab-blog-1/exec {"Cmd":["id"]}   -> 403
DELETE /containers/obslab-migrate-1                    -> 403
POST   /containers/obslab-blog-1/update                -> 403
PUT    /containers/obslab-blog-1/archive?path=/        -> 403
--- reads it does not need
GET    /containers/obslab-blog-1/logs?stdout=1         -> 403
GET    /containers/obslab-blog-1/export                -> 403
GET    /containers/obslab-blog-1/archive?path=/etc/hostname -> 403
GET    /containers/obslab-blog-1/top                   -> 403
GET    /containers/obslab-blog-1/changes               -> 403
GET    /containers/obslab-blog-1/attach/ws?stream=1    -> 403
GET    /images/json /volumes /networks /info /version /_ping /events /system/df /secrets -> 403 each
HEAD   /containers/json                                -> 403
GET    /containers/obslab-blog-1/stop  (X-HTTP-Method-Override: POST) -> 403
--- path tricks (curl --path-as-is)
GET    //containers/json                               -> 403
GET    /containers/./json                              -> 403
GET    /images/../containers/json                      -> 403
GET    /containers/x/../../images/json                 -> 403
GET    /containers/%2e%2e/json                         -> 403
GET    /containers/obslab-blog-1%2Fjson                -> 403
GET    /containers/json?filters=%7B%7D                 -> 403
```

Afterwards `docker ps -a` showed every container in the state it had before.

Why the obvious versions are wrong:

- **`:ro` on the socket mount does not make the API read-only.** `connect()`
  on a read-only bind of a socket works. Through a raw `:ro` mount:
  `POST /containers/obslab-migrate-1/start -> 204`, and the container ran
  again.
- **`tecnativa/docker-socket-proxy` with `CONTAINERS=1` allows far more than
  this needs.** Its switches are per API section and per method, so every
  GET under `/containers` passes. Same lab, `tecnativa/docker-socket-proxy:v0.4.1`:
  `GET /containers/obslab-blog-1/export -> 200 12519936B` (the container's
  whole filesystem as a tar), `GET .../archive?path=/etc/hostname -> 200`,
  `GET .../logs -> 200`, `GET .../top -> 200`. POST was refused (403).
- **A path regex alone is not enough.** The first version matched only
  `path_regexp`, which Caddy applies to the cleaned, decoded path:
  `GET /images/../containers/json` passed it and the raw path went to Docker
  (which answered 301, not the image list, but the proxy should not depend
  on that). The proxy now also matches the raw request-URI as sent: no
  `..`, no `//`, no escapes, a query of plain `key=value`. Side effect,
  kept: container names containing a dot are refused (none on the box).

**Inspect exposes every container's environment to the observer.** The
inspect body carries `Config.Env`, which on the box is every secret in
`/opt/blog/.env` that a service is given (database password, API keys,
`SECRET_KEY_BASE`s). Through the lab proxy: `Config.Env names: POSTGRES_PASSWORD,
POSTGRES_DB, POSTGRES_USER, ...`. There is no inspect without it. The observer
reads `State`, `RestartCount` and `HostConfig.Memory` and drops the rest at the
parse boundary (contract), and the proxy sits on its own network that only the
observer joins: in the lab, from the relay container,
`fetch("http://docker-proxy:2375/containers/json")` fails with `ENOTFOUND`;
from the observer, `docker-proxy` resolves. In production that network is
`internal: true` (no route out; checked: the proxy answers on an internal
network and `wget example.com` from it fails with `bad address`).

## Host numbers

**CPU, memory, load: the container's own `/proc` is the host's.** In a
container limited to `--memory 64m --cpus 0.5`, compared with the Colima VM
(the Docker host) at the same moment:

```
container: MemTotal: 2969088 kB   4 cpu lines   cpu  2037 0 1757 287821 ...   loadavg 0.34 0.10 0.03
host:      MemTotal: 2969088 kB   4 cpu lines   cpu  2040 0 1762 288008 ...   loadavg 0.34 0.10 0.03
```

`/proc/stat`, `/proc/meminfo` and `/proc/loadavg` are not namespaced (Docker
does not use lxcfs), so `HOST_PROC=/proc` with no mount. The release runs as
`nobody` and reads them: the lab observer's `host` source is ok and reports
`mem_total_bytes: 3040346112`, the VM's.

**Disk: `/` inside a container is not the host's root filesystem.** statfs
on a container's `/` reports the filesystem holding Docker's data, because
`/` is overlayfs:

```
container /           blocks=15402443   (= the VM's /var/lib/docker)
VM /                  blocks=4805312
VM /var/lib/docker    blocks=15402443
```

On the box these may coincide (one disk), but that is an assumption, so
production mounts one empty directory read-only, `/var/lib/obs_factor/statfs:/hostfs:ro`,
created by Docker on first `up`. statfs only needs a path on the filesystem;
mounting `/` or `/opt/blog` would expose the host, or `/opt/blog/.env` and
every secret in it. `deploy.sh` checks the directory is on `/` (same
filesystem id as `/`) and warns if not. In the lab `/hostfs` is
`lab/state/hostfs`, on the Mac's disk through Colima's virtiofs, so the lab's
host-disk is the laptop's disk (994 GB, 80%, which matches macOS `df`).

## Postgres

The observer connects as its own role (`deploy/postgres-role.sql`):
`LOGIN CONNECTION LIMIT 1 IN ROLE pg_monitor`. In the lab, with that file:

```
6 pg_stat_database rows, lab_links size 7361 kB       # pg_monitor: every row, any database's size
SELECT from a table owned by blog -> ERROR: permission denied for table pgbench_accounts
second connection -> FATAL: too many connections for role "obs_factor"
at 27 of 30 used  -> FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute
```

The last line is the trade-off to decide with eyes open: the box was at 96
of 100 with 3 reserved for superusers, so this role takes slot 97, the last
ordinary one, and cannot connect once those are gone. Connecting as `blog`
would get in at 97+, by taking a slot kept for an admin fixing exactly that.

## Production wiring

Applied on 2026-11-19: the observer runs at https://factory.bobbby.online
as `obs-factor` in the blog stack, with `docker-proxy` beside it. The
compose file and Caddyfile changes live in the **blog repo**, not only on
the box: `blog/deploy.sh` rsyncs both over `/opt/blog` (the Caddyfile
`--inplace`), so an edit made only on the box is undone by the next blog
deploy. What was applied, for doing it again elsewhere:

| file | what to do with it |
|---|---|
| `deploy/compose.obs-factor.yml` | paste `obs-factor`, `docker-proxy` and the `networks:` block into `blog/docker-compose.yml` |
| `deploy/Caddyfile.patch` | `cd ~/code/blog && patch -p0 Caddyfile < .../deploy/Caddyfile.patch`; ship with `blog/deploy.sh blog` (it reloads Caddy) |
| `deploy/env.example` | three keys for `/opt/blog/.env`, generated on the box |
| `deploy/postgres-role.sql` | run once on the box; the command is in its header |
| `deploy/docker-proxy/Caddyfile` | nothing: `deploy.sh` syncs it to `/opt/obs_factor/deploy/docker-proxy`, which the proxy mounts |

Then `./deploy.sh`.

### The Caddyfile changes, validated

Three additions, nothing existing edited: `metrics { per_host }` in the
global block, next to the existing `servers { ... }`; an `http://:9180 {
metrics }` site; a `factory.bobbby.online` site in the stack's usual shape
(`encode gzip zstd`, `X-Forwarded-Proto`/`alt-svc` headers, `CF-Connecting-IP`
as `X-Real-IP` and `X-Forwarded-For`, `flush_interval -1` for SSE).

The production Caddyfile was copied to `lab/caddy-prod-check/Caddyfile.prod`
(same sha256 as `~/code/blog/Caddyfile`) and patched to `Caddyfile.new`:

```
$ docker run --rm -v "$PWD:/w:ro" caddy:2.10.2 caddy validate --config /w/Caddyfile.prod --adapter caddyfile
Valid configuration
$ ... caddy validate --config /w/Caddyfile.new ...
Valid configuration
$ patch -p0 Caddyfile < deploy/Caddyfile.patch   # on a fresh copy of the blog Caddyfile
patching file Caddyfile                          # cmp: identical to Caddyfile.new
```

Both print the same pre-existing `caddy fmt` warning (two blank lines in the
bobbby.online block); the additions add no fmt changes.

`caddy adapt`, before and after:

```
before: srv0 listen [:443] protocols [h1 h2] trusted_proxies yes  routes 19  hosts 23
after:  srv0 listen [:443] protocols [h1 h2] trusted_proxies yes  routes 20  hosts 24 (+factory)
        srv1 listen [:9180] protocols [h1 h2] trusted_proxies yes routes 1
        http app: metrics {per_host: true}
```

So `srv0`, the server every existing site is on, changes only by the new
route. The unaddressed global `servers { }` block applies to every server,
so the new `:9180` server inherits `protocols h1 h2` and the Cloudflare
`trusted_proxies`: harmless (Caddy logs "HTTP/2 skipped because it requires
TLS" for it and serves HTTP/1.1; `--http2-prior-knowledge` also got 200).

What `validate` does not check, found by running it: upstream names are not
resolved (`reverse_proxy no-such-host.invalid:4000` is valid), `root`
directories need not exist (`/does/not/exist` is valid), and no listener is
bound (validating the lab Caddy's own config inside the running lab Caddy,
with `:80` and `:9180` in use, is valid). It does parse every directive
(`flush_interval nope` fails with `bad duration value`). So the patched file
was also run, in a throwaway `caddy:2.10.2` with `local_certs` added so no
ACME request leaves the laptop:

```
server running  name=srv1 (:9180)                          protocols [h1 h2]
server running  name=remaining_auto_https_redirects (:80)  (automatic HTTP->HTTPS still on for srv0)
server running  name=srv0 (:443)                           protocols [h1 h2]
:80   Host bobbby.online          -> 308 https://bobbby.online/
:80   Host factory.bobbby.online  -> 308 https://factory.bobbby.online/
:443  factory.bobbby.online HTTP/2 -> 502   (no obs-factor upstream here)
:443  bobbby.online/arena/  HTTP/2 -> 502
:443  deciduous.dev         HTTP/2 -> 404   (no /srv/deciduous here)
:9180 /metrics              HTTP/1.1 -> 200
```

Automatic HTTPS for the other sites is unaffected by the plain-HTTP `:9180`
site, and `:9180` is not published by the compose file, so only containers
on `blog_default` can reach it.

SSE through the production site block (the lab's `factory.lab.test`, which
adds only `header_up X-Forwarded-Proto https` because the lab has no TLS
and the release's `force_ssl` would otherwise redirect): `/api/stream`
delivered an event every 5 s both uncompressed and with
`Accept-Encoding: gzip` (`Content-Encoding: gzip`), so `encode` does not
hold events back.

### The compose additions, validated

`deploy/compose.obs-factor.yml` merged with a copy of the production
compose file: `docker compose -p blog -f docker-compose.prod.yml -f deploy/compose.obs-factor.yml config`
is valid; `obs-factor` is on `default` and `obs`, `docker-proxy` only on
`obs` (`blog_obs`, internal), and `config --hash` of `app`, `caddy`, `db`
and `blimp-blog` is the same with and without the additions, so
`up -d obs-factor` recreates nothing else.

### deploy.sh

Marginalia's conventions: the suite gates the deploy on `mix test`'s own
exit status (to a log file, never through a pipe), rsync with excludes,
`-n` dry run, `--host`, `--no-test`, a `.deployed` stamp, and a health check
that wants `ok` and 200 from `https://factory.bobbby.online/health`. It never
edits `/opt/blog`: after syncing it checks, read-only, that both services
are in the compose file, the three Caddyfile additions are there, the
`.env` keys have values (names only are printed) and the Postgres role
exists, and if anything is missing it stops and prints the steps above.

It has not been run against the box. `bash -n deploy.sh` passes; `-n` was run
only with `ssh` replaced by a shim that refuses (it fails loudly with
rsync's exit 255, no connection made) and with a fake `rsync` listing two
changes (it prints the plan, including "restart docker-proxy", and exits 0).
A real `-n` connects: the dry-run rsync runs over ssh, as in marginalia's.

## The release image

`Dockerfile` is marginalia's two stages without Node, assets, Ecto, git or a
C toolchain (no dependency has a NIF). Pins, pulled before pinning:
`hexpm/elixir:1.19.5-erlang-28.3.1-debian-trixie-20260610-slim` and
`debian:trixie-20260610-slim`, marginalia's, so the box should share layers
(1.18.6 tags on OTP 28 do not exist; `1.18.6-erlang-27.3.4.19-...-20261104`
does). There is no `rel/` and no `bin/server`, so it runs
`/app/bin/obs_factor start` with `PHX_SERVER=true`, and copies
`priv/topology` to `/app/topology` so `TOPOLOGY=/app/topology/prod.exs`
does not depend on the app version. 255 MB. Built and run in the lab: all
six sources ok, `GET /health` 200 `ok`, login, `/api/snapshot`, SSE.

## Not done, not known

- The first production snapshot (2026-11-19) had all six sources reading
  and 45 nodes. `/opt/gaming` is mode 700 on the box, so that one site's
  size is unknown and the banner says why; fixing it is a `chmod` in
  whatever deploys that site.
- `caddy:2` is now pinned to `caddy:2.10.2` in the blog repo. The
  `classifier` and `icecast` containers were removed on 2026-11-19 (their
  `docker inspect` output is in `/opt/blog-config-backups/` on the box,
  root-only; the images, `/opt/archive_classifier` and the
  `archive_classifier_prod` database are still there). That freed ten
  Postgres connections: 86 of 100 in use, 87 with the observer.
- Unverified in `priv/topology/prod.exs`, each marked `UNVERIFIED` there:
  dave's `/` (no router found locally), soldat's `/` on :8901 (repo not on
  this laptop), slides-relay answering a plain GET (426 expected), whether
  deciduous-mcp's `/ready` on the box matches the local image, whether the
  Phoenix app's Jetstream client is enabled in the box's config, and which
  S3 provider `bobbby-media` is on.
- Who the external belts are drawn from is the compose env and the apps'
  source: a key being present says an app can call a service, not that it
  does.
