# Topology for lab/compose.yml (compose project "obslab"). See docs/contract.md.
#
# Same shape as prod.exs, so the lab shows every kind of node the box has:
# host-routed apps with databases, a path route on another app's host, a
# memory-limited relay, a static site, a one-shot job that exited 0, and the
# Docker API proxy. Traffic reads left to right on "main": Caddy (col 0),
# apps (col 2-3), Postgres (col 5).
#
# Not here on purpose:
# - the observer itself (compose service "observer"). When it runs in the
#   lab's container it shows up as an unplaced node; when it runs on the
#   laptop with `mix phx.server` there is no container, and a topology entry
#   would make it "down", which would be false.
# - external services: nothing in the lab calls out, and a node for a
#   dependency that does not exist would be simulated data.
#
# Probe ports are the containers' own (whoami listens on 80, the relay on
# 8788), reached by compose service name on the obslab network. When the
# observer runs on the laptop those names do not resolve, so every probe
# fails: that is the truth from there (the README says to run the observer
# container to see probes).

%{
  platforms: [
    %{id: "main", label: "obslab"},
    %{id: "static", label: "static sites (Caddy /srv)"},
    %{id: "host", label: "the laptop (Colima VM)"}
  ],
  nodes: [
    %{id: "caddy", label: "Caddy", kind: :proxy, service: "caddy", platform: "main", pos: {0, 2}},

    # whoami answers /health with 200 until POSTed another code:
    # lab/break.sh 5xx blog on.
    %{id: "blog", label: "Blog", kind: :app, service: "blog", platform: "main", pos: {2, 0},
      hosts: ["blog.lab.test", "www.blog.lab.test"],
      probe: "http://blog:80/health", databases: ["lab_blog"]},
    %{id: "links", label: "Links", kind: :app, service: "links", platform: "main", pos: {2, 2},
      hosts: ["links.lab.test"],
      probe: "http://links:80/health", databases: ["lab_links"]},
    # Path route on blog's host: Caddy counts its requests under
    # blog.lab.test (verified), so its belt is unmetered.
    %{id: "arena", label: "Arena", kind: :app, service: "arena", platform: "main", pos: {3, 0},
      via: ["blog.lab.test/arena/*"], probe: "http://arena:80/health"},
    %{id: "relay", label: "Relay (96 MB)", kind: :relay, service: "relay", platform: "main", pos: {2, 4},
      hosts: ["relay.lab.test"], probe: "http://relay:8788/health"},
    # One-shot, restart "no", exits 0: should read idle, never down.
    %{id: "migrate", label: "Migrate job", kind: :app, service: "migrate", platform: "main", pos: {3, 4}},

    %{id: "db", label: "Postgres", kind: :db, service: "db", platform: "main", pos: {5, 2}},

    %{id: "site-docs", label: "docs.lab.test", kind: :static, site: "docs", platform: "static",
      pos: {0, 0}, hosts: ["docs.lab.test"]},

    %{id: "docker-proxy", label: "Docker API proxy", kind: :relay, service: "docker-proxy",
      platform: "host", pos: {3, 0}}
  ],
  edges: []
}
