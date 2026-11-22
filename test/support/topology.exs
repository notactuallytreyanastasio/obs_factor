# A small topology for the tests, shaped like the box in
# test/fixtures/box/capture.json. Not the production topology (that one is
# priv/topology/*.exs, owned by the lab agent).
%{
  platforms: [
    %{id: "main", label: "bobbby.online"},
    %{id: "host", label: "the box"},
    %{id: "static", label: "static sites"},
    %{id: "outside", label: "outside"}
  ],
  nodes: [
    %{id: "caddy", label: "Caddy", kind: :proxy, service: "caddy", platform: "main", pos: {2, 3}},
    %{
      id: "blimp-blog",
      label: "Blimp blog",
      kind: :app,
      service: "blimp-blog",
      platform: "main",
      pos: {4, 2},
      hosts: ["a.test"],
      probe: "http://blimp-blog:4100/",
      databases: ["blog_prod"]
    },
    %{
      id: "app",
      label: "Phoenix app",
      kind: :app,
      service: "app",
      platform: "main",
      pos: {4, 3},
      hosts: ["b.test"],
      report: "http://app:9568/report",
      databases: ["blog_prod", "nathan_for_us_prod"]
    },
    %{
      id: "soldat",
      label: "Arena",
      kind: :app,
      service: "soldat",
      platform: "main",
      pos: {6, 4},
      via: ["bobbby.online/arena/*"]
    },
    %{
      id: "marginalia",
      label: "Marginalia",
      kind: :app,
      service: "marginalia",
      platform: "main",
      pos: {6, 2}
    },
    %{
      id: "slides-relay",
      label: "Slides relay",
      kind: :relay,
      service: "slides-relay",
      platform: "main",
      pos: {7, 2}
    },
    %{id: "ghost", label: "Ghost", kind: :app, service: "ghost", platform: "main", pos: {8, 2}},
    %{id: "db", label: "Postgres", kind: :db, service: "db", platform: "main", pos: {4, 5}},
    %{
      id: "site-deciduous",
      label: "deciduous.dev",
      kind: :static,
      site: "deciduous",
      platform: "static",
      pos: {0, 0},
      hosts: ["deciduous.test"]
    },
    %{id: "deepseek", label: "DeepSeek", kind: :external, platform: "outside", pos: {0, 0}}
  ],
  edges: [%{from: "blimp-blog", to: "deepseek", item: "prompts"}]
}
