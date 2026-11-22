# traffic: light, real traffic at chosen parts of the site

`traffic.mjs` sends a small, honest stream of `GET`/`HEAD` requests at the
sites listed in `targets.json`, so the factory view shows those nodes busy.
It is for the owner's own hosts only, and it is built to be hard to misuse:
it can only reach hosts in the catalogue, only with GET or HEAD, never on an
`avoid` path, and never faster than 20 req/s unless told otherwise (100 at
most).

Node 20+, no dependencies, no build: `node tools/traffic/traffic.mjs ...`.

## Common cases

```bash
T=tools/traffic/traffic.mjs

node $T list                                   # sites, hosts, paths, avoid rules
node $T run --all --dry-run                    # the plan and sample URLs; sends nothing

# 2 req/s for a minute, split evenly between two nodes
node $T run --site blimp-blog,blinks --rps 2 --duration 60
# ...or 3:1
node $T run --site blimp-blog,blinks --rps 2 --weights blimp-blog=3,blinks=1

# the lab (README "The lab"): everything to Caddy on 18080, catalogue host as Host
node $T run --catalogue tools/traffic/test/lab.json --base http://127.0.0.1:18080 --all --rps 5 --duration 30
# the production catalogue against the lab, renaming hosts
node $T run --site blimp-blog --base http://127.0.0.1:18080 \
  --map bobbby.online=blog.lab.test,www.bobbby.online=www.blog.lab.test --rps 3 --duration 30
```

Always `--dry-run` first: it prints which sites, the expected req/s for each,
and a sample of the exact URLs.

## Selecting

| flag | meaning |
|---|---|
| `--site ID` | a factory node id; all catalogue entries with that id (one node may have several hosts). Repeatable or `a,b`. |
| `--host HOST` | a catalogue hostname; selects every node routed on it (path routes share hosts). With `--site`, both must match. |
| `--all` | everything. One of `--site`, `--host`, `--all` is required. |
| `--kind KIND` | `page`, `asset`, `api`, `notfound`, `redirect`. Repeatable or comma list. |
| `--path-match STR` | only catalogue paths containing STR. |
| `--path /P` | request exactly these paths on the selected hosts instead of the catalogue's. The avoid rules still apply, and a match refuses the whole run. |

## Rate and shape

`--rps` is the **peak** total across everything selected (default 1). It is
split between sites evenly or by `--weights id=3,id2=1` (unnamed sites weigh
1); within a site, paths are picked at random by their `weight`. Arrivals are
a Poisson process (random gaps, not a metronome). `--duration` is required to
be finite (default 60 s, at most 6 h). `--concurrency` (default 8) caps
requests in flight; a paced slot that finds the cap full is skipped and
counted, not queued.

| `--scenario` | shape |
|---|---|
| `steady` (default) | `--rps` throughout |
| `burst` | idle, with a `--burst-len` (3 s) burst at `--rps` at the start of every `--period` (20 s) |
| `wave` | a sine from 10% of `--rps` (at t=0) to 100% (at half a period) and back; `--period` 60 s |
| `visit` | browser-like visits: GET a `page` path, then up to 12 same-origin assets found in its HTML (`script src`, `img src`, `link href` for stylesheets/icons/preloads), then 2-5 s idle. `ceil(--rps)` visitors (at most `--concurrency`) share the `--rps` ceiling; think time keeps the real rate below it. |

`--seed N` makes the paths and gaps reproducible.

## Safety rules (in code, under test)

- **Methods**: only `GET` and `HEAD` can leave the sender; anything else throws.
- **Hosts**: only from the catalogue. There is no URL argument. `--base` (lab
  mode) must be a loopback URL (`localhost`, `127.x`, `::1`), and `--map` only
  works with `--base`.
- **Avoid**: a path matching any `avoid` pattern of its host is never
  requested: catalogue paths that match are dropped with a warning, `--path`
  that matches is refused, assets found in HTML and redirect targets that match
  are skipped. The patterns of every entry on a host apply to that host (path
  routes are the same server). Matching is case-insensitive and also tries the
  path decoded, with `//` collapsed and `..` resolved. `*` matches anything
  (including `/`); `/x/*` also covers `/x`; everything else is literal.
- **Redirects**: not followed; counted as 3xx. With `--follow-redirects`, at
  most 3 hops, only to catalogue hosts (or their `--map` names), never to an
  avoided path, paced like every other request.
- **Rate cap**: `--rps` above 20 is refused unless `--i-know-max-rps N` (N at
  most 100). Independently, the pacer never starts more than `floor(cap)`
  requests in any one-second window, whatever the randomness does.
- **Back-off**: if more than 30% of the last 50 responses (at least 10 seen)
  are 429, 5xx, timeouts or connection errors, the rate drops to 10% and it
  says `BACK-OFF n/3` on stderr. A healthy window at the lower rate restores
  full rate (`recovered`). The third back-off in a row aborts (exit 3). Only
  responses to requests sent after a back-off count toward the next decision.
- **Identity**: `User-Agent: obs-factor-traffic/1 (owner load test)`.
- **Timeouts**: `--timeout` per request, default 10 s.
- **Ctrl-C**: stops sending, waits up to 2 s for in-flight requests, prints the
  summary, exits 130. A second Ctrl-C quits at once.

## Output

On a terminal, one line per second on stderr: sent, ok (2xx+3xx), counts by
2xx/3xx/4xx/5xx/err, req/s over the last second, p50/p95 latency over the
last 200 responses. `--quiet` turns it off. At the end, a per-site table on
stdout, or the same as JSON with `--json`.

Exit codes: 0 done, 1 unexpected error, 2 usage error or refusal (nothing
sent), 3 aborted by back-off, 130 interrupted.

## The catalogue

`targets.json` (default; `--catalogue FILE` for another):

```json
{ "sites": [ {
    "id": "blimp-blog", "label": "Blimp blog", "host": "bobbby.online", "scheme": "https",
    "paths": [ {"path": "/", "weight": 5, "kind": "page", "note": "homepage"} ],
    "avoid": [ {"pattern": "/dtree-ai/*", "why": "calls a paid LLM API"} ]
} ] }
```

It is validated strictly; a malformed entry stops the tool before anything
is sent. `test/lab.json` is the same shape for the lab's hosts.

## Tests

```bash
node --test tools/traffic/test/
```

Unit tests run the engine on a virtual clock with a fake sender (no real
waiting); `test/cli.test.mjs` runs the real CLI against a `node:http` stub on
127.0.0.1 via `--base`. Nothing in the tests touches the internet.

## Layout

- `traffic.mjs`: argument parsing, dry-run plan, list, wiring
- `lib/catalogue.mjs`: catalogue validation, selection, weights, avoid matching
- `lib/shape.mjs`: rate caps, scenario shapes, Poisson pacer, back-off window
- `lib/http.mjs`: the GET/HEAD-only sender (`node:http`/`https`, so `Host` can be set), asset extraction
- `lib/engine.mjs`: the run loop, stats, status line and summary table
