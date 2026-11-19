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
    assert b.hosts == [%{host: "a.test", rps: 2.0, err_rps: 0.0, avg_ms: nil}]
    assert b.container.mem_limit_bytes == 1_610_612_736
    assert b.container.mem_bytes == 361_529_344
    assert_in_delta b.container.cpu_cores, 0.0067, 0.0001
    assert b.container.restarts == 0
    assert b.container.uptime_s == DateTime.diff(Fixtures.now(), ~U[2026-11-05 16:37:17Z])
    assert %{label: "memory", value: "345 MB of 1.5 GB"} in b.facts
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
    assert %{rate: nil, metered: false, label: "bobbby.online/arena/*"} = edge!(s, "caddy>soldat")
    assert %{rate: 10.0, unit: "commits/s", metered: true} = edge!(s, "blimp-blog>db")
    assert %{rate: 10.0} = edge!(s, "app>db")
    assert %{item: "prompts", metered: false, rate: nil} = edge!(s, "blimp-blog>deepseek")
  end

  test "static and external nodes", %{snapshot: s} do
    site = node!(s, "site-deciduous")
    assert site.container == nil
    assert site.holds == [%{label: "deciduous", bytes: 2_048_000}]
    assert site.status == "idle"
    assert site.hosts == [%{host: "deciduous.test", rps: 0.0, err_rps: 0.0, avg_ms: nil}]

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
             ~w(at attention edges host nodes platforms sources tick_ms)

    assert json["sources"]["docker"] == %{
             "ok" => true,
             "at" => "2026-11-18T22:34:52Z",
             "error" => nil
           }

    assert json["at"] == "2026-11-18T22:34:52Z"

    for n <- json["nodes"] do
      assert Map.keys(n) |> Enum.sort() ==
               ~w(container facts headline holds hosts id kind label platform pos probe reason status via)

      if n["status"] not in ["working", "idle"],
        do: assert(is_binary(n["reason"]), "#{n["id"]} has no reason")
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
end
