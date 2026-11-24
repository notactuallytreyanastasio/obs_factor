# Topology for the box: /opt/blog's compose stack behind Caddy, as of
# 2026-11-18. See docs/contract.md for the format.
#
# Sources, all read, none guessed unless a comment says so:
#   - blog/docker-compose.yml (services, ports, env, mem limits)
#   - blog/Caddyfile (every hostname and path route)
#   - test/fixtures/box/capture.json (what actually runs: also classifier,
#     icecast and the exited one-off temper-link; pg_stat_database names)
#   - the apps' own repos under ~/code, for probe paths and outbound calls.
#
# Layout. Platform "main" reads left to right the way a request travels:
#
#   col 0  Caddy
#   col 2  host-routed apps (each owns one or more Caddy hosts)
#   col 3  path-routed apps and relays (a route on someone else's host)
#   col 4  running with no Caddy route at all
#   col 6  Postgres
#
# Static sites Caddy serves from /srv/* are on "static", outside services on
# "outside", the box's own resources and plumbing on "host". `internet` is
# built in and placed by the browser.
#
# Probes go straight to the container on the compose network (not through
# Caddy), so a probe failing means the app, not the route. The observer
# treats any status below 500 as up, so a 404 or 302 on "/" is fine.
#
# `style` names the building the browser draws for a node (docs/contract.md,
# Per-subdomain detail): what the thing is, not what it measures. A node
# without one gets the plain building of its kind.
#
# `report` is where a sub-app serves its own inside (docs/contract.md,
# Reports): the four Phoenix apps that carry vendor/factory_report. Tyler and
# Dave do not yet: their source here does not match what the box runs.
#
# Unverified items are marked UNVERIFIED with what exactly is not known.
#
# `deployed` and `repo` (docs/contract.md, Deploys): the .deployed file each
# app's deploy script writes in /opt/<dir>, seen in the container at
# /host-opt/<dir>/.deployed, and the GitHub repo its sha is in. Without
# `deployed`, /host-opt/<service>/.deployed is tried (marginalia, tyler,
# dave). On 2026-11-23 /opt held five: blog, dave, marginalia, obs_factor,
# tyler. Repos are the origin remotes of the checkouts under ~/code.

%{
  platforms: [
    %{id: "main", label: "bobbby.online"},
    %{id: "static", label: "static sites (Caddy /srv)"},
    %{id: "outside", label: "outside services"},
    %{id: "host", label: "the box"}
  ],
  nodes: [
    # ---------------------------------------------------------------- col 0
    %{id: "caddy", label: "Caddy", kind: :proxy, service: "caddy", platform: "main", pos: {0, 4}},

    # ---------------------------------------------------------------- col 2
    # bobbby.online's count includes the 308s Caddy itself answers (every
    # non-GET not owned by Blimp, every path Blimp does not serve, all sent
    # to old.bobbby.online), and every path-routed request in col 3 below.
    # UNVERIFIED: "/" is a full homepage render on a one-thread server every
    # 5 s; no cheaper route was found in blimp_site/src. It is what the
    # blog's own deploy health check uses.
    %{id: "blimp-blog", label: "Blimp blog", kind: :app, style: "press", service: "blimp-blog",
      platform: "main", pos: {2, 0},
      hosts: ["bobbby.online", "www.bobbby.online"],
      probe: "http://blimp-blog:4100/", databases: ["blog_prod"]},

    # The Phoenix blog. Owns old.bobbby.online; bobbby.online sends it the
    # hotel carbon and tennis potatoes paths directly (handle blocks above
    # @phoenix_write in the Caddyfile).
    %{id: "app", label: "Phoenix blog", kind: :app, style: "foundry", service: "app",
      platform: "main", pos: {2, 1},
      hosts: ["old.bobbby.online"],
      via: ["bobbby.online/hotel-carbon*", "bobbby.online/static/hotel-carbon/*",
            "bobbby.online/tennis-potatoes*", "bobbby.online/static/tennis-potatoes/*"],
      probe: "http://app:4000/", report: "http://app:9568/report", databases: ["blog_prod"],
      # compose builds `app` from /opt/blog (build: .), which blog/deploy.sh writes
      deployed: "/host-opt/blog/.deployed", repo: "notactuallytreyanastasio/blog"},

    # bobbbys.link is host-routed inside the blinks app (Caddyfile comment).
    %{id: "blinks", label: "Blinks", kind: :app, style: "switchyard", service: "blinks",
      platform: "main", pos: {2, 2},
      hosts: ["links.bobbby.online", "bobbbys.link", "www.bobbbys.link"],
      probe: "http://blinks:4000/", report: "http://blinks:9568/report", databases: ["blinks_backend_prod"]},

    %{id: "nathan", label: "Gifmaker", kind: :app, style: "studio", service: "nathan",
      platform: "main", pos: {2, 3},
      hosts: ["gifmaker.bobbby.online"],
      probe: "http://nathan:4001/", report: "http://nathan:9568/report", databases: ["nathan_for_us_prod"]},

    %{id: "marginalia", label: "Marginalia", kind: :app, style: "library", service: "marginalia",
      platform: "main", pos: {2, 4},
      hosts: ["marginalia.bobbby.online"],
      probe: "http://marginalia:4000/", report: "http://marginalia:9568/report", databases: ["marginalia_prod"],
      repo: "notactuallytreyanastasio/marginalia"},

    %{id: "tyler", label: "Tyler", kind: :app, service: "tyler",
      platform: "main", pos: {2, 5},
      hosts: ["tyler.bobbby.online"],
      probe: "http://tyler:4000/", databases: ["tyler_prod"],
      # built from /opt/tyler/app; tyler/deploy.sh writes /opt/tyler/.deployed
      repo: "notactuallytreyanastasio/tyler"},

    # UNVERIFIED: no router.ex was found in ~/code/dave, so "/" is assumed to
    # answer below 500 like the other Phoenix apps.
    %{id: "dave", label: "Dave", kind: :app, style: "conservatory", service: "dave",
      platform: "main", pos: {2, 6},
      hosts: ["dave.bobbby.online"],
      probe: "http://dave:4000/", databases: ["dave_prod"],
      repo: "notactuallytreyanastasio/dave"},

    # No database: reads a snapshot mounted at /data.
    %{id: "skyfeed", label: "Skyfeed", kind: :app, style: "observatory", service: "skyfeed",
      platform: "main", pos: {2, 7},
      hosts: ["bskymapfeeds.bobbby.online"],
      probe: "http://skyfeed:4000/"},

    # This app. Its own probe is GET /health (docs/contract.md, Auth).
    %{id: "obs-factor", label: "Factory (this)", kind: :app, style: "control", service: "obs-factor",
      platform: "main", pos: {2, 8},
      hosts: ["factory.bobbby.online"],
      probe: "http://obs-factor:4000/health",
      deployed: "/host-opt/obs_factor/.deployed", repo: "notactuallytreyanastasio/obs_factor"},

    # ---------------------------------------------------------------- col 3
    # The live Claude Arena watcher (:8901) and 1v1 game server (:8902), both
    # in the one soldat container. UNVERIFIED: the soldat repo is not on this
    # laptop; "/" on :8901 is from the compose comment ("watch.mjs serves
    # the site at /").
    %{id: "soldat", label: "Arena (live)", kind: :app, style: "arena", service: "soldat",
      platform: "main", pos: {3, 0},
      via: ["bobbby.online/arena/*", "bobbby.online/arena/ws"],
      probe: "http://soldat:8901/"},

    # GET /health is in mba-vs-dj/proxy (send 200 {ok, today}).
    %{id: "dtree-ai", label: "dtree-ai", kind: :relay, style: "lab", service: "dtree-ai",
      platform: "main", pos: {3, 1},
      via: ["bobbby.online/dtree-ai/*"],
      probe: "http://dtree-ai:8080/health"},

    # GET /health is in skee_skee_skee/relay/relay.mjs (200 "ok").
    %{id: "skee-relay", label: "Skee relay", kind: :relay, style: "arcade", service: "skee-relay",
      platform: "main", pos: {3, 2},
      via: ["bobbby.online/skee-host/*", "old.bobbby.online/skee-host/*"],
      probe: "http://skee-relay:8788/health"},

    # The only service besides db with a Docker healthcheck, which curls
    # /ready (read from the local deciduous-mcp:local image's config;
    # UNVERIFIED that the box's image is the same).
    %{id: "deciduous-mcp", label: "Deciduous MCP", kind: :app, style: "greenhouse", service: "deciduous-mcp",
      platform: "main", pos: {3, 3},
      via: ["bobbby.online/deciduous-mcp/*"],
      probe: "http://deciduous-mcp:4000/ready", databases: ["deciduous_mcp_prod"]},

    # A bare `ws` WebSocketServer (slides/server/relay.mjs). UNVERIFIED: a
    # plain GET is expected to answer 426 Upgrade Required (the ws library's
    # behaviour for non-upgrade requests), which counts as up.
    %{id: "slides-relay", label: "Slides relay", kind: :relay, style: "stage", service: "slides-relay",
      platform: "main", pos: {3, 5},
      via: ["slides.bobbby.online/relay"],
      probe: "http://slides-relay:8787/"},

    # GET /healthz is in lumines_hd/server/standalone.ts (200).
    %{id: "lumines", label: "Lumines rooms", kind: :relay, style: "arcade", service: "lumines",
      platform: "main", pos: {3, 6},
      via: ["lumines.bobbby.online/ws"],
      probe: "http://lumines:8903/healthz"},

    # ---------------------------------------------------------------- col 4
    # A `docker compose run` of the marginalia image (labels: service
    # marginalia, oneoff True) that ran a folder analysis and exited 0 on
    # 2026-09-20. Matched by name so it never stands in for marginalia.
    %{id: "temper-link", label: "temper-link (one-off)", kind: :app, container: "temper-link",
      platform: "main", pos: {4, 5}},

    # ---------------------------------------------------------------- col 6
    %{id: "db", label: "Postgres", kind: :db, service: "db", platform: "main", pos: {6, 4}},

    # ------------------------------------------------------------- static
    # `site` is the directory name under SITES_DIR, the same name Caddy
    # mounts it under in /srv (deploy/compose.obs-factor.yml mounts each
    # /opt/<dir> read-only at /sites/<site>).
    %{id: "site-deciduous", label: "deciduous.dev", kind: :static, style: "greenhouse", site: "deciduous",
      platform: "static", pos: {0, 0}, hosts: ["deciduous.dev", "www.deciduous.dev"]},
    %{id: "site-phstats", label: "phishjamexplorer.com", kind: :static, style: "conservatory", site: "phstats",
      platform: "static", pos: {1, 0}, hosts: ["phishjamexplorer.com", "www.phishjamexplorer.com"]},
    %{id: "site-soldat-landing", label: "soldat.bobbby.online", kind: :static, style: "arena", site: "soldat-landing",
      platform: "static", pos: {2, 0}, hosts: ["soldat.bobbby.online"]},
    %{id: "site-blimp", label: "blimp.bobbby.online", kind: :static, style: "press", site: "blimp",
      platform: "static", pos: {3, 0}, hosts: ["blimp.bobbby.online"]},
    %{id: "site-gaming", label: "gaming.bobbby.online", kind: :static, style: "arcade", site: "gaming",
      platform: "static", pos: {0, 1}, hosts: ["gaming.bobbby.online"]},
    # slides and lumines: the host belongs to the static build; the relay
    # behind /relay and /ws is a path route (col 3).
    %{id: "site-slides", label: "slides.bobbby.online", kind: :static, style: "stage", site: "slides",
      platform: "static", pos: {1, 1}, hosts: ["slides.bobbby.online"]},
    %{id: "site-lumines", label: "lumines.bobbby.online", kind: :static, style: "arcade", site: "lumines",
      platform: "static", pos: {2, 1}, hosts: ["lumines.bobbby.online"]},
    %{id: "site-downloader", label: "downloader.bobbby.online", kind: :static, site: "downloader",
      platform: "static", pos: {3, 1}, hosts: ["downloader.bobbby.online"]},
    %{id: "site-donny", label: "donny.bobbby.online", kind: :static, site: "donny",
      platform: "static", pos: {0, 2}, hosts: ["donny.bobbby.online"]},
    %{id: "site-padmac", label: "padmac.bobbby.online", kind: :static, site: "padmac",
      platform: "static", pos: {1, 2}, hosts: ["padmac.bobbby.online"]},
    # Only /arena/play/* is served from it (the rest of /arena/* is soldat),
    # so only /opt/arena/play is mounted.
    %{id: "site-arena", label: "Arena replays", kind: :static, style: "arena", site: "arena",
      platform: "static", pos: {2, 2}, via: ["bobbby.online/arena/play/*"]},

    # ------------------------------------------------------------ outside
    %{id: "deepseek", label: "DeepSeek", kind: :external, platform: "outside", pos: {0, 0}},
    %{id: "openai", label: "OpenAI", kind: :external, platform: "outside", pos: {1, 0}},
    %{id: "jetstream", label: "Bluesky Jetstream", kind: :external, platform: "outside", pos: {0, 1}},
    %{id: "bluesky", label: "Bluesky API", kind: :external, platform: "outside", pos: {1, 1}},
    %{id: "github", label: "GitHub API", kind: :external, platform: "outside", pos: {2, 1}},
    %{id: "s3", label: "S3 (bobbby-media)", kind: :external, platform: "outside", pos: {0, 2}},
    %{id: "icloud", label: "iCloud shared album", kind: :external, platform: "outside", pos: {1, 2}},
    %{id: "apns", label: "Apple Push (APNs)", kind: :external, platform: "outside", pos: {0, 3}},
    %{id: "webpush", label: "Web Push services", kind: :external, platform: "outside", pos: {1, 3}},
    %{id: "mta", label: "MTA bus data", kind: :external, platform: "outside", pos: {2, 2}},
    %{id: "noteflight", label: "Noteflight", kind: :external, platform: "outside", pos: {2, 3}},

    # --------------------------------------------------------------- host
    %{id: "docker-proxy", label: "Docker API proxy", kind: :relay, service: "docker-proxy",
      platform: "host", pos: {3, 0}}
  ],

  # Unmetered belts: who calls what, from the compose env (keys present) and
  # the apps' source. A key in the env says the app CAN call; nothing here
  # says how often.
  edges: [
    # DEEPSEEK_API_KEY. blimp-blog reads it as OPENAI_API_KEY with
    # OPENAI_BASE_URL=https://api.deepseek.com, and as AIM_API_KEY.
    %{from: "blimp-blog", to: "deepseek", item: "prompts"},
    %{from: "app", to: "deepseek", item: "prompts"},
    %{from: "marginalia", to: "deepseek", item: "prompts"},
    %{from: "tyler", to: "deepseek", item: "prompts"},
    %{from: "skyfeed", to: "deepseek", item: "prompts"},
    %{from: "dtree-ai", to: "deepseek", item: "prompts"},
    %{from: "skee-relay", to: "deepseek", item: "prompts"},
    # OPENAI_API_KEY: app (OPENAI_MODEL, CAMERA_ANALYST_MODEL); marginalia
    # has the key but defaults to DeepSeek (LLM_PROVIDER).
    %{from: "app", to: "openai", item: "prompts"},
    %{from: "marginalia", to: "openai", item: "prompts"},
    # skyfeed keeps exactly one Jetstream websocket (compose comment); app
    # starts BlueskyJetstream and BlueskyHose (blog/lib/blog/application.ex,
    # on unless :start_bluesky_hoses is false; UNVERIFIED in the box's config).
    %{from: "jetstream", to: "skyfeed", item: "posts"},
    %{from: "jetstream", to: "app", item: "posts"},
    # BLUESKY_USERNAME/APP_PASSWORD (nathan); LIST_BOT_* (skyfeed's lists).
    %{from: "nathan", to: "bluesky", item: "posts"},
    %{from: "skyfeed", to: "bluesky", item: "lists"},
    # api.github.com/users/.../events/public: Blog.GitHub.WorkLogPoller (app)
    # and 99_work_log_poll.blimp (blimp-blog); marginalia's GitHub import.
    %{from: "app", to: "github", item: "events"},
    %{from: "blimp-blog", to: "github", item: "events"},
    %{from: "marginalia", to: "github", item: "imports"},
    # S3_ACCESS_KEY/S3_SECRET_KEY, bucket bobbby-media. UNVERIFIED: which
    # S3-compatible provider.
    %{from: "app", to: "s3", item: "media"},
    %{from: "blimp-blog", to: "s3", item: "media"},
    # ICLOUD_ALBUM_TOKEN, behind /gallery.
    %{from: "icloud", to: "app", item: "photos"},
    %{from: "icloud", to: "blimp-blog", item: "photos"},
    # APNS_* (only the Phoenix Notifier sends APNs, per the Caddyfile).
    %{from: "app", to: "apns", item: "pushes"},
    # VAPID_* keys.
    %{from: "app", to: "webpush", item: "pushes"},
    %{from: "blimp-blog", to: "webpush", item: "pushes"},
    # MTA_API_KEY (/mta-bus-map).
    %{from: "mta", to: "blimp-blog", item: "bus positions"},
    # Noteflight Learning imports (compose comment on dave).
    %{from: "noteflight", to: "dave", item: "scores"}
  ]
}
