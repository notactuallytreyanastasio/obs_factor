defmodule ObsFactor.SnapshotTest do
  use ExUnit.Case, async: true

  alias ObsFactor.{Fixtures, Snapshot}

  setup_all do
    topology = Fixtures.topology()
    sources = Fixtures.sources()

    {snapshot, memory} =
      Snapshot.build(topology, sources, Snapshot.empty_memory(), Fixtures.now())

    {:ok, topology: topology, sources: sources, snapshot: snapshot, memory: memory}
  end

  defp node!(snapshot, id),
    do: Enum.find(snapshot.nodes, &(&1.id == id)) || flunk("no node #{id}")

  defp edge!(snapshot, id),
    do: Enum.find(snapshot.edges, &(&1.id == id)) || flunk("no edge #{id}")

  test "every one of the 19 containers is a node", %{snapshot: s} do
    names = s.nodes |> Enum.map(& &1.container) |> Enum.reject(&is_nil/1) |> Enum.map(& &1.name)
    assert length(names) == 19
    assert length(Enum.uniq(names)) == 19
  end

  test "containers nobody listed are unplaced", %{snapshot: s} do
    for id <- ["classifier", "icecast"] do
      n = node!(s, id)
      assert n.kind == "unplaced"
      assert n.pos == nil
      assert n.platform == nil
      assert n.status == "idle"
    end

    assert node!(s, "icecast").container.name == "blog-icecast-1"
  end

  test "the exited one-off temper-link is idle under its own name, not marginalia", %{snapshot: s} do
    t = node!(s, "temper-link")
    assert t.kind == "unplaced"
    assert t.status == "idle"
    assert t.reason == nil
    assert t.container.state == "exited"
    assert t.container.uptime_s == nil

    m = node!(s, "marginalia")
    assert m.container.name == "blog-marginalia-1"
    assert m.kind == "app"

    refute Enum.any?(s.attention, &(&1.node == "temper-link"))
  end

  test "a service two compose projects share goes to the home project", %{topology: t} do
    docker = Fixtures.docker()
    db = Enum.find(docker.containers, &(&1.name == "blog-db-1"))
    other = %{db | id: "other-db", name: "aaa-other-db-1", project: "aaa"}

    sources =
      Fixtures.sources(%{
        docker: Fixtures.ok(%{docker | containers: [other | docker.containers]})
      })

    {s, _} = Snapshot.build(t, sources, Snapshot.empty_memory(), Fixtures.now())

    assert node!(s, "db").container.name == "blog-db-1"
    assert %{kind: "unplaced"} = node!(s, "aaa-other-db-1")
  end

  test "a scaled service is one node: the other replicas are listed on it, not unplaced", %{topology: t} do
    docker = Fixtures.docker()
    m1 = Enum.find(docker.containers, &(&1.name == "blog-marginalia-1"))
    m2 = %{m1 | id: "m2", name: "blog-marginalia-2", mem_bytes: 2_000_000}
    m3 = %{m1 | id: "m3", name: "blog-marginalia-3", state: "restarting"}

    sources = Fixtures.sources(%{docker: Fixtures.ok(%{docker | containers: [m3, m2 | docker.containers]})})
    {s, _} = Snapshot.build(t, sources, Snapshot.empty_memory(), Fixtures.now())

    m = node!(s, "marginalia")
    assert m.container.name == "blog-marginalia-1"

    assert [%{name: "blog-marginalia-2", state: "running", mem_bytes: 2_000_000}, %{name: "blog-marginalia-3", state: "restarting"}] =
             m.container.replicas

    refute Enum.any?(s.nodes, &(&1.id in ["blog-marginalia-2", "blog-marginalia-3"]))
    assert %{severity: "alert", text: "Marginalia: 2 of 3 replicas running (blog-marginalia-3 restarting)"} =
             Enum.find(s.attention, &(&1.node == "marginalia" and &1.text =~ "replicas"))
  end

  test "a listed service with no container is down", %{snapshot: s} do
    g = node!(s, "ghost")
    assert g.status == "down"
    assert g.reason == "no container"
    assert g.container == nil

    assert %{severity: "alert", text: "Ghost: no container for service ghost"} =
             Enum.find(s.attention, &(&1.node == "ghost"))
  end

  test "a listed node carries the container, probe, hosts and facts", %{snapshot: s} do
    b = node!(s, "blimp-blog")
    assert b.kind == "app"
    assert b.platform == "main"
    assert b.pos == [4, 2]
    assert b.status == "working"
    assert b.headline == %{value: 2.0, unit: "req/s"}
    assert b.probe == %{ok: true, code: 200, ms: 12, error: nil}

    assert b.hosts == [
             %{
               host: "a.test",
               rps: 2.0,
               err_rps: 0.0,
               avg_ms: 8.0,
               codes: %{"2xx" => 1.6, "3xx" => 0.0, "4xx" => 0.4, "5xx" => 0.0, "other" => 0.0},
               in_bps: 200.0,
               out_bps: 12_000.0,
               in_flight: 2
             }
           ]

    assert b.container.mem_limit_bytes == 1_610_612_736
    assert b.container.mem_bytes == 361_529_344
    assert_in_delta b.container.cpu_cores, 0.0067, 0.0001
    assert b.container.restarts == 0
    assert b.container.uptime_s == DateTime.diff(Fixtures.now(), ~U[2026-11-05 16:37:17Z])
    assert %{label: "memory", value: "345 MB of 1.5 GB"} in b.facts
    assert %{label: "a.test", value: "2.00 req/s, 8.0 ms, 2 in flight, 12 KB/s out"} in b.facts
  end

  test "an unlimited container reports no limit", %{snapshot: s} do
    db = node!(s, "db")
    assert db.container.mem_limit_bytes == nil
    assert %{label: "memory", value: "736 MB, no limit"} in db.facts
  end

  test "db holds its databases and is blocked at 96 of 100 connections", %{snapshot: s} do
    db = node!(s, "db")
    assert %{label: "blog_prod", bytes: 2_594_723_507} = hd(db.holds)
    assert length(db.holds) == 9
    assert db.status == "blocked"
    assert db.reason == "96 of 100 connections"
    assert db.headline == %{value: 10.0, unit: "commits/s"}

    assert %{node: "db", severity: "alert", text: "Postgres at 96 of 100 connections"} in s.attention
  end

  test "the three resource nodes and the internet source", %{snapshot: s} do
    cpu = node!(s, "host-cpu")
    assert cpu.kind == "resource"
    assert cpu.container == nil
    assert cpu.platform == "host"
    assert cpu.headline == %{value: 0.076, unit: "cores"}

    disk = node!(s, "host-disk")
    assert disk.headline == %{value: 86.4, unit: "%"}
    assert disk.status == "blocked"

    assert [%{label: "used", bytes: 133_432_082_432}, %{label: "free", bytes: 20_938_870_784}] =
             disk.holds

    assert %{node: "host-disk", severity: "warn", text: "host disk 86% full"} in s.attention

    assert node!(s, "host-mem").headline.value == 4_786_737_152

    i = node!(s, "internet")
    assert i.kind == "source"
    assert i.container == nil
    assert i.status == "working"
  end

  test "derived belts", %{snapshot: s} do
    assert %{from: "internet", to: "caddy", rate: 2.0, metered: true} = edge!(s, "internet>caddy")

    assert %{rate: 2.0, metered: true, label: "a.test", unit: "req/s"} =
             edge!(s, "caddy>blimp-blog")

    assert %{rate: +0.0, metered: true} = edge!(s, "caddy>app")
    # A path route is metered by the access log.
    assert %{rate: 2.0, metered: true, label: "bobbby.online/arena/*", unit: "req/s"} =
             edge!(s, "caddy>soldat")

    assert %{rate: 10.0, unit: "commits/s", metered: true} = edge!(s, "blimp-blog>db")
    assert %{rate: 10.0} = edge!(s, "app>db")
    assert %{item: "prompts", metered: false, rate: nil} = edge!(s, "blimp-blog>deepseek")
  end

  test "static and external nodes", %{snapshot: s} do
    site = node!(s, "site-deciduous")
    assert site.container == nil
    assert site.holds == [%{label: "deciduous", bytes: 2_048_000}]
    assert site.status == "idle"

    # Caddy is read and has never seen this host: zeros, not unknowns.
    assert site.hosts == [
             %{
               host: "deciduous.test",
               rps: 0.0,
               err_rps: 0.0,
               avg_ms: nil,
               codes: %{"2xx" => 0.0, "3xx" => 0.0, "4xx" => 0.0, "5xx" => 0.0, "other" => 0.0},
               in_bps: 0.0,
               out_bps: 0.0,
               in_flight: 0
             }
           ]

    assert %{label: "deciduous.test", value: "0.00 req/s, 0 in flight, 0 B/s out"} in site.facts

    ext = node!(s, "deepseek")
    assert ext.status == "unknown"
    assert ext.container == nil
  end

  test "the proxy lists every host Caddy reports", %{snapshot: s} do
    caddy = node!(s, "caddy")
    assert Enum.map(caddy.hosts, & &1.host) == ["a.test", "b.test"]
    assert caddy.headline == %{value: 2.0, unit: "req/s"}
  end

  test "attention is worst first", %{snapshot: s} do
    sevs = Enum.map(s.attention, & &1.severity)
    assert sevs == Enum.sort_by(sevs, &(&1 != "alert"))
    assert hd(sevs) == "alert"
  end

  test "it encodes to the contract's JSON shape", %{snapshot: s} do
    json = s |> Jason.encode!() |> Jason.decode!()

    assert Map.keys(json) |> Enum.sort() ==
             ~w(at attention builder edges host nodes platforms sources tick_ms)

    # No builder configured: the key is there and null.
    assert json["builder"] == nil

    assert json["sources"]["docker"] == %{
             "ok" => true,
             "at" => "2026-11-18T22:34:52Z",
             "error" => nil
           }

    assert json["at"] == "2026-11-18T22:34:52Z"

    for n <- json["nodes"] do
      extra =
        cond do
          n["via"] != [] -> ~w(via_codes via_rps)
          n["id"] == "internet" -> ~w(clients)
          true -> []
        end

      assert Map.keys(n) |> Enum.sort() ==
               Enum.sort(
                 ~w(build container facts headline holds hosts id inside kind label latency platform pos probe reason routes status style via) ++
                   extra
               )

      for h <- n["hosts"] do
        assert Map.keys(h) |> Enum.sort() ==
                 ~w(avg_ms codes err_rps host in_bps in_flight out_bps rps)
      end

      if n["status"] not in ["working", "idle"],
        do: assert(is_binary(n["reason"]), "#{n["id"]} has no reason")
    end
  end

  @zero_codes %{"2xx" => 0.0, "3xx" => 0.0, "4xx" => 0.0, "5xx" => 0.0, "other" => 0.0}

  test "the JSON of one host entry and one edge", %{snapshot: s} do
    json = s |> Jason.encode!() |> Jason.decode!()
    node = Enum.find(json["nodes"], &(&1["id"] == "blimp-blog"))

    assert node["hosts"] == [
             %{
               "host" => "a.test",
               "rps" => 2.0,
               "err_rps" => 0.0,
               "avg_ms" => 8.0,
               "codes" => %{
                 "2xx" => 1.6,
                 "3xx" => 0.0,
                 "4xx" => 0.4,
                 "5xx" => 0.0,
                 "other" => 0.0
               },
               "in_bps" => 200.0,
               "out_bps" => 12_000.0,
               "in_flight" => 2
             }
           ]

    assert Enum.find(json["edges"], &(&1["id"] == "caddy>blimp-blog")) == %{
             "id" => "caddy>blimp-blog",
             "from" => "caddy",
             "to" => "blimp-blog",
             "item" => "requests",
             "rate" => 2.0,
             "unit" => "req/s",
             "metered" => true,
             "label" => "a.test",
             "codes" => %{"2xx" => 1.6, "3xx" => 0.0, "4xx" => 0.4, "5xx" => 0.0, "other" => 0.0}
           }

    for e <- json["edges"] do
      assert Map.keys(e) |> Enum.sort() == ~w(codes from id item label metered rate to unit)
    end
  end

  test "codes on belts: summed where Caddy meters, nil elsewhere", %{snapshot: s} do
    fed = %{"2xx" => 1.6, "3xx" => 0.0, "4xx" => 0.4, "5xx" => 0.0, "other" => 0.0}
    assert edge!(s, "internet>caddy").codes == fed
    assert edge!(s, "caddy>blimp-blog").codes == fed
    assert edge!(s, "caddy>app").codes == @zero_codes
    assert edge!(s, "caddy>site-deciduous").codes == @zero_codes

    # A path route's classes come from the access log.
    assert edge!(s, "caddy>soldat").codes ==
             %{"2xx" => 1.8, "3xx" => 0.0, "4xx" => 0.0, "5xx" => 0.2, "other" => 0.0}

    # Database and topology-listed belts carry no classes.
    assert edge!(s, "blimp-blog>db").codes == nil
    assert edge!(s, "blimp-blog>deepseek").codes == nil
  end

  test "a belt over several hosts sums each class, and one unknown host makes it nil" do
    topology =
      update_in(Fixtures.topology(), [:nodes], fn nodes ->
        Enum.map(nodes, fn
          %{id: "blimp-blog"} = n -> %{n | hosts: ["a.test", "b.test", "c.test"]}
          %{id: "app"} = n -> %{n | hosts: []}
          n -> n
        end)
      end)

    host = fn rps, codes ->
      %{
        rps: rps,
        err_rps: codes["5xx"],
        avg_ms: nil,
        codes: codes,
        in_bps: 0.0,
        out_bps: 0.0,
        in_flight: 0
      }
    end

    a = host.(3.0, %{"2xx" => 2.0, "3xx" => 0.5, "4xx" => 0.25, "5xx" => 0.0, "other" => 0.25})
    b = host.(1.0, %{"2xx" => 0.5, "3xx" => 0.0, "4xx" => 0.5, "5xx" => 0.0, "other" => 0.0})
    caddy = %{hosts: %{"a.test" => a, "b.test" => b}, total_rps: 4.0, reset: false}

    build = fn caddy ->
      {s, _} =
        Snapshot.build(
          topology,
          Fixtures.sources(%{caddy: Fixtures.ok(caddy)}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      s
    end

    # c.test has no series: zero, since Caddy is read.
    summed = %{"2xx" => 2.5, "3xx" => 0.5, "4xx" => 0.75, "5xx" => 0.0, "other" => 0.25}
    s = build.(caddy)
    assert edge!(s, "caddy>blimp-blog").codes == summed
    assert edge!(s, "internet>caddy").codes == summed

    unknown_b = %{b | rps: nil, err_rps: nil, codes: nil, in_bps: nil, out_bps: nil}
    s = build.(%{caddy | hosts: %{"a.test" => a, "b.test" => unknown_b}, total_rps: nil})
    assert edge!(s, "caddy>blimp-blog").codes == nil
    assert edge!(s, "caddy>blimp-blog").rate == nil
    assert edge!(s, "internet>caddy").codes == nil
  end

  test "first scrape: rates and classes unknown, in-flight already known", %{topology: t} do
    text =
      String.replace(
        Fixtures.caddy_text(),
        ~s(caddy_http_requests_in_flight{handler="subroute",host="a.test",server="srv0"} 0),
        ~s(caddy_http_requests_in_flight{handler="subroute",host="a.test",server="srv0"} 3)
      )

    first = ObsFactor.Caddy.rates(nil, ObsFactor.Caddy.reading(text, Fixtures.now_ms()))
    sources = Fixtures.sources(%{caddy: Fixtures.ok(first)})
    {s, _} = Snapshot.build(t, sources, Snapshot.empty_memory(), Fixtures.now())

    unknown = %{rps: nil, err_rps: nil, avg_ms: nil, codes: nil, in_bps: nil, out_bps: nil}

    b = node!(s, "blimp-blog")
    assert b.hosts == [Map.merge(unknown, %{host: "a.test", in_flight: 3})]
    # Unknown bytes are left out of the fact line, never shown as zero.
    assert %{label: "a.test", value: "unknown, 3 in flight"} in b.facts

    # A host with no series has nothing in flight, but its rates are not zero yet.
    assert node!(s, "site-deciduous").hosts ==
             [Map.merge(unknown, %{host: "deciduous.test", in_flight: 0})]

    assert edge!(s, "internet>caddy").codes == nil
    assert edge!(s, "caddy>blimp-blog").codes == nil
  end

  test "a failing Caddy source: every host field and every belt's codes are nil", %{topology: t} do
    sources = Fixtures.sources(%{caddy: Fixtures.failed("connection refused")})
    {s, _} = Snapshot.build(t, sources, Snapshot.empty_memory(), Fixtures.now())

    b = node!(s, "blimp-blog")

    assert b.hosts == [
             %{
               host: "a.test",
               rps: nil,
               err_rps: nil,
               avg_ms: nil,
               codes: nil,
               in_bps: nil,
               out_bps: nil,
               in_flight: nil
             }
           ]

    assert %{label: "a.test", value: "unknown"} in b.facts
    # The path route's belt is the access log's, which still answers.
    assert Enum.all?(s.edges, &(&1.codes == nil or &1.id == "caddy>soldat"))
    assert edge!(s, "caddy>soldat").rate == 2.0
  end

  test "style passes through from the topology, nil everywhere else", %{topology: t} do
    styled =
      update_in(t, [:nodes], fn nodes ->
        Enum.map(nodes, fn
          %{id: id} = n when id in ["blimp-blog", "site-deciduous", "deepseek", "caddy"] ->
            %{n | style: "press-#{n.kind}"}

          n ->
            n
        end)
      end)

    {s, _} = Snapshot.build(styled, Fixtures.sources(), Snapshot.empty_memory(), Fixtures.now())

    assert node!(s, "blimp-blog").style == "press-app"
    assert node!(s, "site-deciduous").style == "press-static"
    assert node!(s, "deepseek").style == "press-external"
    assert node!(s, "caddy").style == "press-proxy"

    # Listed without a style, resource, source and unplaced nodes.
    for id <- ["app", "db", "host-cpu", "host-mem", "host-disk", "internet", "icecast"] do
      assert node!(s, id).style == nil, "#{id} has a style"
    end
  end

  test "a failing source makes its nodes unknown and raises an alert", %{topology: t} do
    sources =
      Fixtures.sources(%{
        docker: Fixtures.failed("connection refused"),
        host: Fixtures.failed("cannot read /proc/stat")
      })

    {s, _} = Snapshot.build(t, sources, Snapshot.empty_memory(), Fixtures.now())

    assert node!(s, "blimp-blog").status == "unknown"
    assert node!(s, "blimp-blog").reason == "docker source failing"
    assert node!(s, "host-cpu").status == "unknown"
    assert s.host.cores == nil
    refute Enum.any?(s.nodes, &(&1.kind == "unplaced"))

    assert %{node: nil, severity: "alert", text: "docker source failing: connection refused"} in s.attention

    assert %{ok: false, error: "connection refused", at: nil} = s.sources.docker
  end

  test "working is remembered for a minute after traffic stops", %{topology: t, memory: memory} do
    quiet = Fixtures.sources(%{caddy: Fixtures.ok(%{hosts: %{}, total_rps: 0.0, reset: false})})

    {s, _} = Snapshot.build(t, quiet, memory, DateTime.add(Fixtures.now(), 30))
    assert node!(s, "blimp-blog").status == "working"

    {s, _} = Snapshot.build(t, quiet, memory, DateTime.add(Fixtures.now(), 61))
    assert node!(s, "blimp-blog").status == "idle"
  end

  describe "access log" do
    test "sources.access is reported like the others", %{snapshot: s} do
      assert s.sources.access == %{ok: true, at: "2026-11-18T22:34:52Z", error: nil}

      assert Map.keys(s.sources) |> Enum.sort() ==
               ~w(access caddy docker host postgres probes reports sites)a
    end

    test "a path-route node: routes, latency, via rates, a metered belt, a req/s headline", %{
      snapshot: s
    } do
      json = s |> Jason.encode!() |> Jason.decode!()
      soldat = Enum.find(json["nodes"], &(&1["id"] == "soldat"))

      assert soldat["routes"] == [
               %{
                 "path" => "/arena/",
                 "count" => 6,
                 "rps" => 0.02,
                 "errors" => 0,
                 "p95_ms" => 1.96
               },
               %{
                 "path" => "/arena/assets/app.js",
                 "count" => 3,
                 "rps" => 0.01,
                 "errors" => 0,
                 "p95_ms" => 0.41
               },
               %{
                 "path" => "/arena/x",
                 "count" => 1,
                 "rps" => 0.003,
                 "errors" => 1,
                 "p95_ms" => 251.03
               }
             ]

      assert soldat["latency"] == %{
               "p50_ms" => 1.96,
               "p95_ms" => 251.03,
               "p99_ms" => 251.03,
               "count" => 10
             }

      assert soldat["via_rps"] == 2.0

      assert soldat["via_codes"] ==
               %{"2xx" => 1.8, "3xx" => 0.0, "4xx" => 0.0, "5xx" => 0.2, "other" => 0.0}

      assert soldat["headline"] == %{"value" => 2.0, "unit" => "req/s"}
      assert soldat["status"] == "working"

      assert Enum.find(json["edges"], &(&1["id"] == "caddy>soldat")) == %{
               "id" => "caddy>soldat",
               "from" => "caddy",
               "to" => "soldat",
               "item" => "requests",
               "rate" => 2.0,
               "unit" => "req/s",
               "metered" => true,
               "label" => "bobbby.online/arena/*",
               "codes" => soldat["via_codes"]
             }
    end

    test "a host's node has routes and latency but no via fields", %{snapshot: s} do
      b = node!(s, "blimp-blog")

      assert b.routes == [
               %{path: "/", count: 4, rps: 0.013, errors: 0, p95_ms: 7.84},
               %{path: "/posts/1", count: 1, rps: 0.003, errors: 0, p95_ms: 0.98}
             ]

      assert b.latency == %{count: 5, p50_ms: 7.84, p95_ms: 7.84, p99_ms: 7.84}
      refute Map.has_key?(b, :via_rps)
      refute Map.has_key?(b, :via_codes)
      # Its belt and headline are still Caddy's counters.
      assert b.headline == %{value: 2.0, unit: "req/s"}
    end

    test "a node the log has nothing for: no routes, no latency", %{snapshot: s} do
      for id <- ["app", "db", "host-cpu", "internet", "icecast", "deepseek"] do
        n = node!(s, id)
        assert n.routes == [], id
        assert n.latency == nil, id
      end
    end

    test "internet says who is asking", %{snapshot: s} do
      assert node!(s, "internet").clients == %{
               classes: %{browser: 13, bot: 1, tool: 2, other: 0},
               countries: [
                 %{code: "US", count: 10},
                 %{code: "DE", count: 5},
                 %{code: "??", count: 1}
               ],
               window_s: 300
             }

      refute Map.has_key?(node!(s, "caddy"), :clients)
    end

    test "the proxy's facts say what was read", %{snapshot: s} do
      facts = node!(s, "caddy").facts
      assert %{label: "access log", value: "17 lines in 300 s"} in facts
      assert %{label: "access log bad lines", value: "1"} in facts
      assert %{label: "access log skipped", value: "0 B"} in facts
      assert %{label: "access log rotations", value: "0"} in facts
      assert %{label: "access log unrouted", value: "1 requests"} in facts
    end

    test "a quiet path route reads zero, not unknown", %{topology: t} do
      {data, _} =
        ObsFactor.AccessLog.step(
          Fixtures.access_state(),
          [],
          %{skipped_bytes: 0, rotations: 0},
          Fixtures.now_ms()
        )

      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{access: Fixtures.ok(data)}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      soldat = node!(s, "soldat")
      assert soldat.routes == []
      assert soldat.latency == nil
      assert soldat.via_rps == 0.0
      assert soldat.via_codes == @zero_codes
      assert soldat.headline == %{value: 0.0, unit: "req/s"}
      belt = edge!(s, "caddy>soldat")
      assert belt.rate == 0.0 and belt.metered
      assert belt.codes == @zero_codes
    end

    test "a failing access source: the detail is nil and nothing else changes", %{
      topology: t,
      snapshot: ok
    } do
      sources = Fixtures.sources(%{access: Fixtures.failed("ACCESS_LOG is not set")})
      {s, _} = Snapshot.build(t, sources, Snapshot.empty_memory(), Fixtures.now())

      assert s.sources.access == %{ok: false, at: nil, error: "ACCESS_LOG is not set"}

      assert %{node: nil, severity: "alert", text: "access source failing: ACCESS_LOG is not set"} in s.attention

      for n <- s.nodes do
        assert n.routes == nil, n.id
        assert n.latency == nil, n.id
      end

      soldat = node!(s, "soldat")
      assert soldat.via_rps == nil
      assert soldat.via_codes == nil
      # As before the access log: CPU for a headline, an unmetered belt.
      # (The capture has no stats for this container, so its CPU is unknown.)
      assert soldat.headline == %{value: nil, unit: "cores"}

      assert %{rate: nil, metered: false, codes: nil, label: "bobbby.online/arena/*"} =
               edge!(s, "caddy>soldat")

      assert node!(s, "internet").clients == nil
      assert %{label: "access log", value: "unknown"} in node!(s, "caddy").facts

      # No node turns unknown for it: every status is what it was, except the
      # arena, which the log alone showed working.
      for n <- s.nodes, n.id != "soldat" do
        assert {n.id, n.status, n.reason} ==
                 {n.id, node!(ok, n.id).status, node!(ok, n.id).reason}
      end

      assert soldat.status in ["idle", "working"]

      assert Enum.reject(s.edges, &(&1.id == "caddy>soldat")) ==
               Enum.reject(ok.edges, &(&1.id == "caddy>soldat"))
    end

    test "after one read the source is ok and every number is still nil", %{topology: t} do
      sources = Fixtures.sources(%{access: Fixtures.ok(%{ready: false})})
      {s, _} = Snapshot.build(t, sources, Snapshot.empty_memory(), Fixtures.now())

      assert s.sources.access.ok
      refute Enum.any?(s.attention, &(&1.text =~ "access"))

      for n <- s.nodes do
        assert n.routes == nil, n.id
        assert n.latency == nil, n.id
      end

      soldat = node!(s, "soldat")
      assert soldat.via_rps == nil
      assert soldat.via_codes == nil
      # The belt is metered, its rate not yet known.
      assert soldat.headline == %{value: nil, unit: "req/s"}
      assert %{rate: nil, metered: true, codes: nil} = edge!(s, "caddy>soldat")
      assert node!(s, "internet").clients == nil
      assert %{label: "access log", value: "unknown"} in node!(s, "caddy").facts
    end

    test "a read that saw a rotation has tables but no rates", %{topology: t} do
      {data, _} =
        ObsFactor.AccessLog.step(
          Fixtures.access_state(),
          Fixtures.access_lines(),
          %{skipped_bytes: 0, rotations: 1},
          Fixtures.now_ms()
        )

      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{access: Fixtures.ok(data)}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      soldat = node!(s, "soldat")
      assert length(soldat.routes) == 3
      assert soldat.via_rps == nil
      assert soldat.via_codes == nil
      assert %{rate: nil, metered: true, codes: nil} = edge!(s, "caddy>soldat")

      assert %{
               label: "access log rotations",
               value: "1 (what was unread in the old file is lost)"
             } in node!(
               s,
               "caddy"
             ).facts
    end
  end

  describe "reports" do
    defp reports_failing(error, at \\ nil) do
      Fixtures.ok(%{"app" => %{ok: false, error: error, at: at}})
    end

    test "sources.reports is reported like the others", %{snapshot: s} do
      assert s.sources.reports == %{ok: true, at: "2026-11-18T22:34:52Z", error: nil}
    end

    test "a node without a report URL has no inside", %{snapshot: s} do
      for n <- s.nodes, n.id != "app" do
        assert n.inside == nil, "#{n.id} has an inside"
      end

      json = s |> Jason.encode!() |> Jason.decode!()
      blog = Enum.find(json["nodes"], &(&1["id"] == "blimp-blog"))
      assert Map.fetch!(blog, "inside") == nil
    end

    test "the JSON of a report read twice", %{snapshot: s} do
      json = s |> Jason.encode!() |> Jason.decode!()
      inside = Enum.find(json["nodes"], &(&1["id"] == "app"))["inside"]

      assert inside == %{
               "ok" => true,
               "error" => nil,
               "at" => "2026-11-18T22:34:52Z",
               "runtime" => %{
                 "kind" => "beam",
                 "versions" => %{
                   "otp" => "28",
                   "elixir" => "1.19.5",
                   "phoenix" => "1.7.19",
                   "phoenix_live_view" => "1.0.3",
                   "app" => "0.1.0"
                 },
                 "uptime_s" => 12350,
                 "gauges" => %{
                   "memory.total" => 123_456_789,
                   "process.count" => 812,
                   "run_queue" => 0
                 },
                 "rates" => %{"reductions" => 51_200.0, "io.out_bytes" => 1_000.0}
               },
               "units" => [
                 %{
                   "kind" => "liveview",
                   "name" => "BlogWeb.PostLive",
                   "route" => "/post/:slug",
                   "count" => 3,
                   "gauges" => %{"memory" => 812_345, "message_queue" => 0},
                   "members" => [
                     %{
                       "id" => "9f2c1a",
                       "label" => "/post/the-factory-must-grow",
                       "since" => "2026-11-19T07:31:02Z",
                       "gauges" => %{"memory" => 301_234, "message_queue" => 0},
                       "counters" => %{"events" => 14}
                     }
                   ]
                 }
               ],
               # Busiest first by rate.
               "streams" => [
                 %{
                   "kind" => "db.query",
                   "name" => "Blog.Repo",
                   "by" => nil,
                   "count" => 99_170,
                   "rate" => 10.0,
                   "err_rate" => 0.0,
                   "avg_ms" => 0.5
                 },
                 %{
                   "kind" => "http.route",
                   "name" => "GET /post/:slug",
                   "by" => nil,
                   "count" => 4416,
                   "rate" => 1.2,
                   "err_rate" => 0.0,
                   "avg_ms" => 22.4
                 },
                 %{
                   "kind" => "outbound.http",
                   "name" => "api.deepseek.com",
                   "by" => nil,
                   "count" => 42,
                   "rate" => 0.2,
                   "err_rate" => 0.2,
                   "avg_ms" => 2000.0
                 },
                 %{
                   "kind" => "liveview.event",
                   "name" => "BlogWeb.PostLive#like",
                   "by" => nil,
                   "count" => 120,
                   "rate" => 0.0,
                   "err_rate" => 0.0,
                   "avg_ms" => nil
                 }
               ],
               "events" => [],
               "truncated" => %{"units" => 0, "members" => 0, "streams" => 0},
               "cluster" => nil,
               "members" => nil
             }
    end

    defp liveapp_twice do
      {:ok, first} = ObsFactor.Reports.validate(Fixtures.liveapp_doc())
      {:ok, second} = ObsFactor.Reports.validate(Fixtures.liveapp_doc_later())
      new = ObsFactor.Reports.new_node()
      {_, state} = ObsFactor.Reports.step(new, {:ok, first}, Fixtures.now_ms() - 5_000)
      {data, _} = ObsFactor.Reports.step(state, {:ok, second}, Fixtures.now_ms())
      data
    end

    test "the real reporter's report read twice: by on rows, events, totals first", %{
      topology: t
    } do
      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: Fixtures.ok(%{"app" => liveapp_twice()})}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      json = s |> Jason.encode!() |> Jason.decode!()
      inside = Enum.find(json["nodes"], &(&1["id"] == "app"))["inside"]

      assert inside["ok"] == true

      # Totals busiest first, then the breakdown row, though it is as busy
      # as the busiest total.
      assert inside["streams"] == [
               %{
                 "kind" => "db.query",
                 "name" => "Liveapp.Repo",
                 "by" => nil,
                 "count" => 50,
                 "rate" => 2.0,
                 "err_rate" => 0.0,
                 "avg_ms" => 0.2
               },
               %{
                 "kind" => "log",
                 "name" => "warning",
                 "by" => nil,
                 "count" => 3,
                 "rate" => 0.2,
                 "err_rate" => 0.0,
                 "avg_ms" => 0.0
               },
               %{
                 "kind" => "liveview.event",
                 "name" => "LiveappWeb.CounterLive#inc",
                 "by" => nil,
                 "count" => 10,
                 "rate" => 0.0,
                 "err_rate" => 0.0,
                 "avg_ms" => nil
               },
               %{
                 "kind" => "http.route",
                 "name" => "GET /",
                 "by" => nil,
                 "count" => 3,
                 "rate" => 0.0,
                 "err_rate" => 0.0,
                 "avg_ms" => nil
               },
               %{
                 "kind" => "db.query",
                 "name" => "Liveapp.Repo",
                 "by" => %{"kind" => "liveview", "name" => "LiveappWeb.CounterLive"},
                 "count" => 40,
                 "rate" => 2.0,
                 "err_rate" => 0.0,
                 "avg_ms" => 0.2
               }
             ]

      assert inside["events"] == [
               %{
                 "at" => "2026-11-19T08:12:33Z",
                 "level" => "warning",
                 "name" => "LiveappWeb.RoomLive",
                 "message" => "room 42 is getting loud",
                 "by" => %{"kind" => "liveview", "name" => "LiveappWeb.RoomLive"}
               }
             ]

      assert Enum.map(inside["units"], & &1["route"]) == ["/", nil]
      assert inside["runtime"]["gauges"]["port.limit"] == 65536
      assert inside["runtime"]["rates"]["reductions"] == 10_000.0
      assert inside["runtime"]["rates"]["report.handler_errors"] == 0.0
    end

    test "the cut at 40 takes breakdown rows before any total", %{topology: t} do
      %{"app" => report} = Fixtures.reports()

      row = fn name, by, rate ->
        %{kind: "custom", name: name, by: by, count: 1, rate: rate, err_rate: 0.0, avg_ms: nil}
      end

      # 30 quiet totals and 30 busy breakdown rows.
      totals = for i <- 1..30, do: row.("t#{i}", nil, i / 100)
      parts = for i <- 1..30, do: row.("t1", %{kind: "unit", name: "u#{i}"}, 100.0 + i)
      report = %{report | streams: parts ++ totals}

      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: Fixtures.ok(%{"app" => report})}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      inside = node!(s, "app").inside
      assert length(inside.streams) == 40

      assert Enum.map(inside.streams, &{&1.name, &1.by && &1.by.name}) ==
               Enum.map(30..1//-1, &{"t#{&1}", nil}) ++ Enum.map(30..21//-1, &{"t1", "u#{&1}"})

      assert inside.truncated.streams == 20

      # More totals than fit: only totals, the busiest 40.
      report = %{report | streams: parts ++ for(i <- 1..45, do: row.("t#{i}", nil, i / 100))}

      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: Fixtures.ok(%{"app" => report})}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      inside = node!(s, "app").inside
      assert Enum.map(inside.streams, & &1.name) == Enum.map(45..6//-1, &"t#{&1}")
      assert Enum.all?(inside.streams, &(&1.by == nil))
      assert inside.truncated.streams == 35
    end

    test "one read: the inside is there, its rates are nil, streams by count", %{topology: t} do
      {:ok, reading} = ObsFactor.Reports.validate(Fixtures.report_doc())

      {data, _} =
        ObsFactor.Reports.step(ObsFactor.Reports.new_node(), {:ok, reading}, Fixtures.now_ms())

      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: Fixtures.ok(%{"app" => data})}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      inside = node!(s, "app").inside
      assert inside.ok
      assert inside.runtime.rates == %{"reductions" => nil, "io.out_bytes" => nil}
      assert inside.runtime.gauges["process.count"] == 812

      assert Enum.map(inside.streams, &{&1.name, &1.count, &1.rate, &1.err_rate, &1.avg_ms}) == [
               {"Blog.Repo", 99_120, nil, nil, nil},
               {"GET /post/:slug", 4410, nil, nil, nil},
               {"BlogWeb.PostLive#like", 120, nil, nil, nil},
               {"api.deepseek.com", 41, nil, nil, nil}
             ]
    end

    test "streams are cut at 40, busiest first, and the cut is counted", %{topology: t} do
      %{"app" => report} = Fixtures.reports()

      streams =
        for i <- 1..50 do
          %{
            kind: "custom",
            name: "s#{i}",
            by: nil,
            count: 1000 - i,
            # s1..s10 have no rate yet; the rest are busier the higher they are.
            rate: if(i > 10, do: i / 1, else: nil),
            err_rate: if(i > 10, do: 0.0, else: nil),
            avg_ms: nil
          }
        end

      report = %{report | streams: streams, truncated: %{units: 0, members: 0, streams: 7}}

      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: Fixtures.ok(%{"app" => report})}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      inside = node!(s, "app").inside
      assert length(inside.streams) == 40
      assert Enum.map(inside.streams, & &1.name) == Enum.map(50..11//-1, &"s#{&1}")
      assert inside.truncated == %{units: 0, members: 0, streams: 17}
    end

    test "a failing report: why, when it last worked, every other key nil, same status", %{
      topology: t,
      snapshot: ok
    } do
      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{
            reports: reports_failing("connection refused", ~U[2026-11-18 22:34:42.123Z])
          }),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      app = node!(s, "app")

      assert app.inside == %{
               ok: false,
               error: "connection refused",
               at: "2026-11-18T22:34:42Z",
               runtime: nil,
               units: nil,
               streams: nil,
               events: nil,
               truncated: nil,
               cluster: nil,
               members: nil
             }

      assert {app.status, app.reason} == {node!(ok, "app").status, node!(ok, "app").reason}

      assert %{
               node: "app",
               severity: "warn",
               text: "Phoenix app report failing: connection refused"
             } in s.attention

      refute Enum.any?(ok.attention, &(&1.text =~ "report failing"))
    end

    test "a report that never worked has no time", %{topology: t} do
      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: reports_failing("unknown factory_report version 2")}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      assert %{ok: false, error: "unknown factory_report version 2", at: nil} =
               node!(s, "app").inside
    end

    test "a failing reports source: the inside says so, the alert is the source's alone", %{
      topology: t
    } do
      {s, _} =
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: Fixtures.failed("timed out after 4250 ms")}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      assert node!(s, "app").inside == %{
               ok: false,
               error: "reports source failing: timed out after 4250 ms",
               at: nil,
               runtime: nil,
               units: nil,
               streams: nil,
               events: nil,
               truncated: nil,
               cluster: nil,
               members: nil
             }

      assert %{
               node: nil,
               severity: "alert",
               text: "reports source failing: timed out after 4250 ms"
             } in s.attention

      refute Enum.any?(s.attention, &(&1.node == "app" and &1.text =~ "report"))
    end

    test "a node with a report URL the collector said nothing about is a bug, said loudly", %{
      topology: t
    } do
      assert_raise ArgumentError, ~r/no result for node "app"/, fn ->
        Snapshot.build(
          t,
          Fixtures.sources(%{reports: Fixtures.ok(%{})}),
          Snapshot.empty_memory(),
          Fixtures.now()
        )
      end
    end
  end
end
