defmodule ObsFactor.DiscoveryTest do
  use ExUnit.Case, async: true

  alias ObsFactor.{Discovery, Snapshot}

  # The fields Topology.validate/1 gives every node.
  defp node(id, kind, extra) do
    Map.merge(
      %{id: id, label: id, kind: kind, style: nil, service: nil, container: nil, site: nil, platform: "main",
        pos: {0, 0}, hosts: [], via: [], probe: nil, report: nil, databases: []},
      extra
    )
  end

  @topology %{
    platforms: [%{id: "main", label: "m"}, %{id: "host", label: "the box"}],
    nodes: [
      %{id: "caddy", label: "Caddy", kind: :proxy, style: nil, service: "caddy", container: nil, site: nil,
        platform: "main", pos: {0, 0}, hosts: [], via: [], probe: nil, report: nil, databases: []},
      %{id: "blog", label: "Blog", kind: :app, style: nil, service: "app", container: nil, site: nil,
        platform: "main", pos: {1, 0}, hosts: ["blog.test"], via: [], probe: nil,
        report: "http://app:9568/report", databases: ["blog_prod"]},
      %{id: "quiet", label: "Quiet", kind: :app, style: nil, service: "quiet", container: nil, site: nil,
        platform: "main", pos: {1, 1}, hosts: [], via: [], probe: nil, report: nil, databases: []},
      %{id: "db", label: "Postgres", kind: :db, style: nil, service: "db", container: nil, site: nil,
        platform: "main", pos: {3, 0}, hosts: [], via: [], probe: nil, report: nil, databases: []}
    ],
    edges: []
  }

  # A container as ObsFactor.Docker.Parse.list_entry/1 makes it.
  defp container(name, service, labels, extra \\ %{}) do
    Map.merge(
      %{id: "id-" <> name, name: name, image: "x", state: "running", status_text: "Up 3 minutes",
        service: service, project: "blog", oneoff: false, labels: labels},
      extra
    )
  end

  test "a labelled container no topology entry claims becomes an app on the proxy's platform" do
    c =
      container("blog-ledger-1", "ledger", %{
        "report" => "http://ledger:9568/report",
        "label" => "Ledger",
        "hosts" => "ledger.test, www.ledger.test",
        "databases" => "ledger_prod"
      })

    {t, problems} = Discovery.merge(@topology, [c])
    assert problems == []

    assert %{id: "ledger", label: "Ledger", kind: :app, service: "ledger", container: nil, platform: "main", pos: nil,
             hosts: ["ledger.test", "www.ledger.test"], report: "http://ledger:9568/report",
             databases: ["ledger_prod"], discovered: true} = Enum.find(t.nodes, &(&1.id == "ledger"))

    assert Discovery.report_targets(@topology, [c]) == [{"ledger", "http://ledger:9568/report"}]
    # and its belts are derived like a topology node's
    keys = ObsFactor.Topology.derived_edge_keys(t)
    assert {"caddy", "ledger"} in keys and {"ledger", "db"} in keys
  end

  test "the topology wins: a contradiction keeps the static value and is reported, a gap is filled" do
    blog =
      container("blog-app-1", "app", %{
        "report" => "http://app:9999/report",
        "label" => "Phoenix blog",
        "hosts" => "blog.test,new.blog.test"
      })

    quiet = container("blog-quiet-1", "quiet", %{"report" => "http://quiet:9568/report", "databases" => "quiet_prod"})

    {t, problems} = Discovery.merge(@topology, [blog, quiet])

    b = Enum.find(t.nodes, &(&1.id == "blog"))
    assert b.report == "http://app:9568/report"
    assert b.label == "Blog"
    # hosts were set statically: kept, not merged
    assert b.hosts == ["blog.test"]

    q = Enum.find(t.nodes, &(&1.id == "quiet"))
    assert q.report == "http://quiet:9568/report"
    assert q.databases == ["quiet_prod"]
    assert q.pos == {1, 1}

    texts = Enum.map(problems, fn {"warn", t} -> t end)

    assert ~s[container blog-app-1 (node blog): obs_factor.report says "http://app:9999/report", the topology says "http://app:9568/report"; the topology wins] in texts
    assert Enum.any?(texts, &(&1 =~ ~s(obs_factor.hosts says "blog.test,new.blog.test", the topology says "blog.test")))
    assert Enum.any?(texts, &(&1 =~ ~s(obs_factor.label says "Phoenix blog", the topology says "Blog")))
    assert length(problems) == 3

    # only the filled-in report is a new target; blog's was already static
    assert Discovery.report_targets(@topology, [blog, quiet]) == [{"quiet", "http://quiet:9568/report"}]
  end

  test "agreeing labels on a topology node say nothing" do
    c = container("blog-app-1", "app", %{"report" => "http://app:9568/report", "hosts" => "blog.test", "label" => "Blog"})
    assert {%{nodes: nodes}, []} = Discovery.merge(@topology, [c])
    assert nodes == @topology.nodes
  end

  test "a taken id leaves the container unplaced; a taken host is left off; nothing is silent" do
    # its service is new but it asks for the id of the db node
    steal_id = container("x-1", "x", %{"report" => "http://x:9568/report", "id" => "db"})
    steal_host = container("y-1", "y", %{"report" => "http://y:9568/report", "hosts" => "blog.test,y.test"})
    bad_url = container("z-1", "z", %{"report" => "z:9568/report"})
    bad_platform = container("w-1", "w", %{"report" => "http://w:9568/report", "platform" => "mars"})

    {t, problems} = Discovery.merge(@topology, [steal_id, steal_host, bad_url, bad_platform])
    ids = Enum.map(t.nodes, & &1.id)
    refute "x" in ids or "z" in ids
    assert %{hosts: ["y.test"]} = Enum.find(t.nodes, &(&1.id == "y"))
    assert %{platform: "main"} = Enum.find(t.nodes, &(&1.id == "w"))

    assert [
             {"warn", "container w-1: obs_factor.platform \"mars\" is not a platform of the topology; placed on \"main\""},
             {"warn", "container x-1: not placed: id \"db\" is already a node; the topology wins (set obs_factor.id)"},
             {"warn", "container y-1: host \"blog.test\" belongs to node blog; the topology wins, left off"},
             {"warn", "container z-1: not placed: obs_factor.report \"z:9568/report\" is not an http(s) URL"}
           ] = problems
  end

  test "replicas of a scaled service are one node; a one-off run never connects" do
    labels = %{"report" => "http://ledger:9568/report"}
    a = container("blog-ledger-2", "ledger", labels)
    b = container("blog-ledger-1", "ledger", labels)
    run = container("blog-ledger-run-1", "ledger", labels, %{oneoff: true})
    {t, []} = Discovery.merge(@topology, [a, b, run])
    assert Enum.count(t.nodes, &(&1.id == "ledger")) == 1

    {t, []} = Discovery.merge(@topology, [run])
    refute Enum.any?(t.nodes, &(&1.id == "ledger"))
  end

  test "a container without a compose service is matched by its name, and an obs_factor.id is used" do
    c = container("hand-started", nil, %{"report" => "http://hand-started:9568/report", "id" => "hand"})
    {t, []} = Discovery.merge(@topology, [c])
    assert %{id: "hand", container: "hand-started", service: nil} = Enum.find(t.nodes, &(&1.id == "hand"))
  end

  test "a builder container with obs_factor.id and obs_factor.report is placed once, by discovery" do
    c = container("obsbuild-deci", nil, %{"id" => "deci", "report" => "http://obsbuild-deci:9568/report"})
    {t, problems, _} = ObsFactor.Labelled.merge(@topology, [c], [])
    assert problems == []
    assert [%{report: "http://obsbuild-deci:9568/report"}] = Enum.filter(t.nodes, &(&1.id == "deci"))
  end

  describe "in a snapshot" do
    defp sources(containers, reports) do
      ok = fn data -> %{ok: true, at: ~U[2026-11-23 00:00:00Z], error: nil, data: data} end
      bad = %{ok: false, at: nil, error: "off", data: nil}

      %{docker: ok.(%{containers: containers}), caddy: bad, postgres: bad, host: bad, probes: ok.(%{}),
        sites: bad, access: bad, reports: reports}
    end

    test "a labelled container is a building with its report, not unplaced; a conflict is in attention" do
      # as ObsFactor.Docker.assemble/3 leaves them: no inspect or stats this tick
      read = %{inspect: nil, inspect_error: nil, stats_error: nil, mem_bytes: nil, cpu_cores: nil,
               net_rx_bps: nil, net_tx_bps: nil, restarts_recent: 0}
      ledger = container("blog-ledger-1", "ledger", %{"report" => "http://ledger:9568/report", "label" => "Ledger"}, read)
      blog = container("blog-app-1", "app", %{"report" => "http://app:1/report"}, read)

      {s, _} =
        Snapshot.build(@topology, sources([ledger, blog], %{ok: false, at: nil, error: "off", data: nil}),
          Snapshot.empty_memory(), ~U[2026-11-23 00:00:05Z])

      n = Enum.find(s.nodes, &(&1.id == "ledger"))
      assert n.kind == "app" and n.label == "Ledger" and n.platform == "main" and n.pos == nil
      assert n.container.name == "blog-ledger-1"
      # it has a report URL, so it has an inside, failing with the source
      assert n.inside.error =~ "reports source failing"
      refute Enum.any?(s.nodes, &(&1.kind == "unplaced" and &1.id == "ledger"))

      assert Enum.any?(s.attention, &(&1.severity == "warn" and &1.text =~ "obs_factor.report says \"http://app:1/report\""))
    end

    # Found running the observer against a fake Docker: the reports
    # collector reads a label's URL only from the round after Docker listed
    # it, and the snapshot raised "reports source has no result for node".
    test "a report URL from labels that the collector has not read yet is 'not read yet', not a crash" do
      read = %{inspect: nil, inspect_error: nil, stats_error: nil, mem_bytes: nil, cpu_cores: nil,
               net_rx_bps: nil, net_tx_bps: nil, restarts_recent: 0}
      quiet = container("blog-quiet-1", "quiet", %{"report" => "http://quiet:9568/report"}, read)
      ledger = container("blog-ledger-1", "ledger", %{"report" => "http://ledger:9568/report"}, read)
      reports = %{ok: true, at: ~U[2026-11-23 00:00:00Z], error: nil, data: %{"blog" => %{ok: false, error: "refused", at: nil}}}

      {s, _} = Snapshot.build(@topology, sources([quiet, ledger], reports), Snapshot.empty_memory(), ~U[2026-11-23 00:00:05Z])

      for id <- ["quiet", "ledger"] do
        assert Enum.find(s.nodes, &(&1.id == id)).inside.error ==
                 "not read yet: connected by its labels since the last read"
      end

      # a topology report the collector skipped is still a bug, and still raises
      assert_raise ArgumentError, ~r/no result for node "blog"/, fn ->
        Snapshot.build(@topology, sources([quiet], %{reports | data: %{}}), Snapshot.empty_memory(), ~U[2026-11-23 00:00:05Z])
      end
    end
  end

  test "node/3 matches what Topology.validate/1 returns, so the fixtures above are honest" do
    {:ok, t} =
      ObsFactor.Topology.validate(%{
        platforms: [%{id: "main", label: "m"}],
        nodes: [%{id: "quiet", label: "quiet", kind: :app, service: "quiet", platform: "main", pos: {0, 0}}]
      })

    assert hd(t.nodes) == %{node("quiet", :app, %{service: "quiet"}) | pos: [0, 0]}
  end
end
