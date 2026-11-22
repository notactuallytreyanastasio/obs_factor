# Traffic targets: notes

`targets.json` lists the GET paths that are safe to request repeatedly on the owner's sites, and the paths that must never be requested. It was compiled on 2026-11-19 from these sources:

- `~/code/blog/Caddyfile`
- `~/code/blog/docker-compose.yml`
- `priv/topology/prod.exs`, which supplies the node ids
- each app's router or build

Each path's `note` names its source and the status observed in a single live check (one GET per path, 1.2 s apart, 79 requests in total). There were no 403, 429 or Cloudflare challenges. Paths marked "NOT requested" were left out of the check to stay within budget and are unverified.

How `traffic.mjs` reads this file (`lib/catalogue.mjs`):

- Avoid rules are **unioned per host**: a rule in any entry applies to every entry on that host.
- `*` matches anything, including `/` and the empty string.
- A pattern ending in `/*` also matches the bare prefix.

So there are no catch-all rules like `/dtree-ai/*`, because they would forbid that node's own `/health`. Visitor mode also fetches same-host assets referenced by each page, and the avoid rules filter those too.

## Per site

| id | host | paths (observed) | source | main avoids |
|---|---|---|---|---|
| blimp-blog | bobbby.online | `/` 200, `/robots.txt` 200, `/favicon.ico` 200, `/privacy` 200, `/blog` 200, `/post/this-site-is-blimp-now` 200, `/blog/tag/blimp` 200, `/assets/base.css` 200, `/be-elixir` 200, `/tetris` (unverified), `/__obs-traffic-404` **308** to old.bobbby.online | `blog/blimp_site/main.blimp` fixed routes, `data/posts.txt` | `/stumble/go*` (GET increments `stumble_count`), `/live/*` (ws), admin/curate, `/api/blinks*` and `/api/push/*` (push), receipt printer, collage (S3), gallery (iCloud), large files (sky points 4.8 MB, phish_lab JSON, piet, wasm), DB-per-request JSON |
| blimp-blog | www.bobbby.online | `/` 200, `/robots.txt` (unverified) | same Caddy block | the key bobbby.online avoids, repeated here |
| app | old.bobbby.online | `/robots.txt` 200, `/favicon.ico` (unverified), `/privacy` 200, `/chess` 200, `/frontier` (unverified), `/` 200 (**303 KB**, weight 1), `/__obs-traffic-404` 404 | `blog/lib/blog_web/router.ex`, `priv/static` | `/live/*` and `/socket/*` (ws), `/admin/*`, `/api/*`, `/blinks/review` (votes send pushes), LLM chat pages (ziggy, lolly, rooted_in_good, who), `/cameras` (OpenAI), S3 tools, MTA, keylogger and cursor pages |
| app | bobbby.online (via) | `/hotel-carbon` 200, `/hotel-carbon/studio` (unverified), `/static/hotel-carbon/style.css` 200, `/tennis-potatoes` 200, `/static/tennis-potatoes/assets/index-4KL6pzjz.css` 200, `/hotel-carbon/__obs-traffic-404` 404 | `HotelCarbonController`, `TennisPotatoesController` | `/hotel-carbon/library` (400 KB), map-data JS bundles (375 to 842 KB) |
| blinks | links.bobbby.online | none | `blinks_backend` `router.ex` | **all**: no DNS record |
| blinks | bobbbys.link, www.bobbbys.link | none | | **all**: DNS goes to Namecheap (apex) and its parking page (www), not the box |
| nathan | gifmaker.bobbby.online | `/` 200, `/gifs` 200, `/robots.txt` (unverified), 404 | `nathan_for_us` `router.ex` | `post=1` (posts to Bluesky), GIF and frame DB blobs, `/video/*`, users and admin (prod LiveDashboard), media dirs, `/live/*` |
| marginalia | marginalia.bobbby.online | `/` 200, `/sitemap.xml` 200, `/cases` 200 (151 KB, weight 1), `/robots.txt` (unverified), 404 | `marginalia` `router.ex` | `/works*`, `/import*`, `/stacks*`, `/cuts*` and `/links*`: **each cookieless GET creates a guest user row**; chat pages (DeepSeek) |
| tyler | tyler.bobbby.online | `/` 200, `/library` 200, `/robots.txt` (unverified), 404 | `tyler/app` `router.ex` | `/search*` (`smart=1` calls DeepSeek), `/read/*` (LLM), `/files/*` (PDFs), `/documents/*` |
| dave | dave.bobbby.online | `/` 200, `/__obs/traffic/404` 404 | `_from-macbook/notedance_viewer` `router.ex` | `/app*` (404 live, see below), musicxml, imports and issues (`settle_stuck` writes), api, ws |
| skyfeed | bskymapfeeds.bobbby.online | `/` 200, `/feed` 200, `/robots.txt` (unverified), 404 | `bsky_exploration/skyfeed` | `/feed/*.*` and `/feed/did*` (Bluesky API plus a long-lived FeedServer), `/atlas.json` (large) |
| obs-factor | factory.bobbby.online | `/health` 200, `/login` 200, 404 | `lib/obs_factor_web/router.ex` | `/`, `/api/*` (session; `/api/stream` is SSE), `/logout` |
| soldat | bobbby.online | `/arena/` 200 (97 KB) | Caddyfile only (source not local) | `/arena/ws`, `/arena/data.json*`, `/arena/desk-data.json*` |
| site-arena | bobbby.online | `/arena/play/` 200 | Caddyfile | none listed (file list unknown) |
| dtree-ai | bobbby.online | `/dtree-ai/health` 200 | `mba-vs-dj/proxy/server.mjs` | `/dtree-ai/edit*`, `/explain*`, `/ideas*`: DeepSeek |
| skee-relay | bobbby.online, old.bobbby.online | `/skee-host/health` 200 on both | `skee_skee_skee/relay/relay.mjs` | `/skee-host/chat*`: DeepSeek, and its counters increment before the body is checked |
| deciduous-mcp | bobbby.online | `/deciduous-mcp/health` 200, `/deciduous-mcp/ready` 200 | `deciduous/deciduous_mcp` `web/router.ex` | `mcp` (SSE), `events` (ws), `tokens`, `export`, `documents`, `messages`, the write routes |
| slides-relay | slides.bobbby.online | none | `slides/server/relay.mjs` | `/relay*` (ws) |
| lumines | lumines.bobbby.online | none | `lumines_hd/server/standalone.ts` | `/ws*` (ws) |
| site-deciduous | deciduous.dev | `/` 200, `/llms.txt` 200, 404 | `deciduous/docs` | graph-data.json (1.2 MB), demo bundle, search index |
| site-deciduous | www.deciduous.dev | none | | **all**: no DNS record |
| site-phstats | phishjamexplorer.com (+www) | `/` 200, `/vite.svg` 200; www `/` 200 | `phstats/public` | `tracks.json` (11.9 MB), `/assets/*` (hashes unknown); no 404 possible (SPA fallback) |
| site-soldat-landing | soldat.bobbby.online | `/` 200, 404 | Caddyfile only | none |
| site-blimp | blimp.bobbby.online | `/` 200, `/tutorial/` 200, 404 | `blimp/docs` | `blimp.wasm`, blog PNGs |
| site-gaming | gaming.bobbby.online | `/favicon.svg` 200, `/game/main.js` 200, 404 | `whats_going_through_your_mind` | `og.png`, three.js, `game.js`, `/v/*` |
| site-slides | slides.bobbby.online | `/` 200, `/favicon.svg` 200 | `slides/public` | `/relay*`, `og.png`; no 404 possible (SPA) |
| site-lumines | lumines.bobbby.online | `/` 200, `/league` 200, `/deck/` 200 | `lumines_hd`, Caddyfile rewrite | `/deck/shots/*` (up to 1.5 MB), `/ws*`; no 404 possible |
| site-downloader | downloader.bobbby.online | `/` 200, 404 | `nathan_for_us/site` | release binaries (GitHub) |
| site-donny | donny.bobbby.online | none | not found | **all**: no DNS record |
| site-padmac | padmac.bobbby.online | `/` 200, 404 | `padmac/site` | `og.png` |

## The link-shortener hosts

`blinks_backend`'s router has **no shortlink redirect and no click counting**, so nothing on links.bobbby.online or bobbbys.link increments a counter on GET today. `/stumble` and `/blinks/stumble` pick a random link and send a 302 to a third-party site, and both are avoided. None of the three hosts reaches the box, though: links.bobbby.online and www.deciduous.dev have no DNS record, and the bobbbys.link domains resolve to Namecheap. Every path on those hosts is avoided. If the hosts come back, these routes are cheap: `/blinks` (301), `/rss`, `/robots.txt`, `/`, and `/` on bobbbys.link (the static LandingController).

## Not found locally

- The soldat arena watcher, the 1v1 game server and the soldat landing page: their sources exist only on the box.
- The arena play client (`publish.mjs`).
- donny.
- Built `dist/` directories for phstats, slides and lumines, so their hashed `/assets/*` names are unknown.
- Dave's deployed source: `~/code/dave` is a Temper library. The app is `~/code/_from-macbook/notedance_viewer`, but live `/app` answered 404, so that copy does not match the box.
- The deployed blimp.bobbby.online `/` is 38 KB, but `blimp/docs/index.html` locally is 2.6 KB, so the deployed build is newer.

## Unverified

- The paths marked "NOT requested" in `targets.json`.
- Whether the Phoenix LiveView pages on old.bobbby.online (`/cameras`, `/mta-bus-map`, `/typewriter`, `/cursor-tracker`) do anything on a plain render. They are avoided to be safe.
- Every soldat watcher path other than `/arena/`. It may serve more JSON polled every 5 s; only the two big data files are named.
- `/arena/play/*` beyond its index.
- Whether a plain GET on slides `/relay` answers 426. Nothing was requested there.
- The deciduous.dev box copy is assumed to mirror `deciduous/docs/`.
