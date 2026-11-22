defmodule ObsFactor.RulesTest do
  use ExUnit.Case, async: true

  alias ObsFactor.{Fixtures, Snapshot}

  setup_all do
    {:ok, topology: Fixtures.topology(), docker: Fixtures.docker()}
  end

  defp with_container(docker, name, fun) do
    %{
      docker
      | containers:
          Enum.map(docker.containers, fn c -> if c.name == name, do: fun.(c), else: c end)
    }
  end

  defp inspect_set(c, fields), do: %{c | inspect: Map.merge(c.inspect, fields)}

  defp build(topology, overrides) do
    {s, _} =
      Snapshot.build(
        topology,
        Fixtures.sources(overrides),
        Snapshot.empty_memory(),
        Fixtures.now()
      )

    s
  end

  defp node!(s, id), do: Enum.find(s.nodes, &(&1.id == id))
  defp attention(s, id), do: Enum.filter(s.attention, &(&1.node == id))

  test "a container that is not running is down", %{topology: t, docker: d} do
    d =
      with_container(
        d,
        "blog-app-1",
        &inspect_set(%{&1 | state: "exited"}, %{running: false, status: "exited", exit_code: 137})
      )

    s = build(t, %{docker: Fixtures.ok(d)})
    assert %{status: "down", reason: "exited (code 137)"} = node!(s, "app")
    assert [%{severity: "alert", text: "Phoenix app: exited (code 137)"}] = attention(s, "app")
  end

  test "a one-off that exited non-zero is down, not idle", %{topology: t, docker: d} do
    d = with_container(d, "temper-link", &inspect_set(&1, %{exit_code: 1}))
    s = build(t, %{docker: Fixtures.ok(d)})
    assert %{status: "down", reason: "exited (code 1)"} = node!(s, "temper-link")
  end

  test "restart loop", %{topology: t, docker: d} do
    d = with_container(d, "blog-app-1", &%{&1 | restarts_recent: 4})
    s = build(t, %{docker: Fixtures.ok(d)})
    assert %{status: "down", reason: "restart loop (4 restarts in 15 min)"} = node!(s, "app")

    d = with_container(Fixtures.docker(), "blog-app-1", &inspect_set(&1, %{restarting: true}))
    assert %{status: "down"} = node!(build(t, %{docker: Fixtures.ok(d)}), "app")
  end

  test "restarting with no rise seen says restarting, not a made-up count", %{
    topology: t,
    docker: d
  } do
    d = with_container(d, "blog-app-1", &inspect_set(&1, %{restarting: true, running: true}))

    assert %{status: "down", reason: "restarting"} =
             node!(build(t, %{docker: Fixtures.ok(d)}), "app")
  end

  test "restart counting survives a reset by docker restart" do
    # 4, 5, 6, then `docker restart` resets to 0, then the loop goes on: 1, 2.
    history = Enum.with_index([4, 5, 6, 0, 1, 2], fn c, i -> {i * 5_000, c} end)
    assert ObsFactor.Docker.restarts_in_window(history) == 4
  end

  test "one recent restart is a warning only", %{topology: t, docker: d} do
    d = with_container(d, "blog-app-1", &%{&1 | restarts_recent: 1})
    s = build(t, %{docker: Fixtures.ok(d)})
    refute node!(s, "app").status == "down"

    assert [%{severity: "warn", text: "Phoenix app: restarted 1x in 15 min"}] =
             attention(s, "app")
  end

  test "probe failing", %{topology: t} do
    s =
      build(t, %{
        probes:
          Fixtures.ok(%{"blimp-blog" => %{ok: false, code: 502, ms: 3, error: "answered 502"}})
      })

    assert %{status: "down", reason: "probe failed: answered 502"} = node!(s, "blimp-blog")
    assert node!(s, "blimp-blog").probe == %{ok: false, code: 502, ms: 3, error: "answered 502"}
    assert [%{severity: "alert"}] = attention(s, "blimp-blog")
  end

  test "memory within 10% of a real limit", %{topology: t, docker: d} do
    d = with_container(d, "blog-blimp-blog-1", &%{&1 | mem_bytes: 1_500_000_000})
    s = build(t, %{docker: Fixtures.ok(d)})
    assert %{status: "blocked", reason: "memory at 93% of limit"} = node!(s, "blimp-blog")

    assert [%{severity: "warn", text: "Blimp blog: memory 1.4 GB of 1.5 GB limit"}] =
             attention(s, "blimp-blog")
  end

  test "a failing probe does not hide memory near the limit", %{topology: t, docker: d} do
    d = with_container(d, "blog-blimp-blog-1", &%{&1 | mem_bytes: 1_500_000_000})
    probes = Fixtures.ok(%{"blimp-blog" => %{ok: false, code: nil, ms: nil, error: "timed out"}})
    s = build(t, %{docker: Fixtures.ok(d), probes: probes})
    assert %{status: "down"} = node!(s, "blimp-blog")

    assert [%{severity: "alert"}, %{severity: "warn", text: "Blimp blog: memory" <> _}] =
             attention(s, "blimp-blog")
  end

  test "no limit, no memory rule (Docker's host-sized limit is not a limit)", %{
    topology: t,
    docker: d
  } do
    d = with_container(d, "blog-db-1", &%{&1 | mem_bytes: 16_000_000_000})
    s = build(t, %{docker: Fixtures.ok(d)})
    refute Enum.any?(attention(s, "db"), &(&1.text =~ "memory"))

    host_sized =
      with_container(
        Fixtures.docker(),
        "blog-app-1",
        &inspect_set(%{&1 | mem_bytes: 16_300_000_000}, %{memory_limit: 16_368_988_160})
      )

    s = build(t, %{docker: Fixtures.ok(host_sized)})
    assert node!(s, "app").container.mem_limit_bytes == nil
  end

  test "Postgres connections: 90 of 100 is fine, 91 is an alert", %{topology: t} do
    s = build(t, %{postgres: Fixtures.ok(Fixtures.postgres(90))})
    refute node!(s, "db").status == "blocked"
    s = build(t, %{postgres: Fixtures.ok(Fixtures.postgres(91))})
    assert node!(s, "db").status == "blocked"
  end

  test "host disk thresholds", %{topology: t} do
    h = Fixtures.host()
    s = build(t, %{host: Fixtures.ok(%{h | disk_used_bytes: 100, disk_avail_bytes: 900})})
    assert node!(s, "host-disk").status == "working"
    assert attention(s, "host-disk") == []

    s = build(t, %{host: Fixtures.ok(%{h | disk_used_bytes: 970, disk_avail_bytes: 30})})
    assert [%{severity: "alert", text: "host disk 97% full"}] = attention(s, "host-disk")
  end

  test "a host's 5xx rate", %{topology: t} do
    caddy = %{
      hosts: %{
        "a.test" => %{
          rps: 3.0,
          err_rps: 0.4,
          avg_ms: 8.0,
          codes: %{"2xx" => 2.6, "3xx" => 0.0, "4xx" => 0.0, "5xx" => 0.4, "other" => 0.0},
          in_bps: 0.0,
          out_bps: 0.0,
          in_flight: 0
        }
      },
      total_rps: 3.0,
      reset: false
    }

    s = build(t, %{caddy: Fixtures.ok(caddy)})
    assert %{status: "blocked", reason: "5xx at 0.40/s on a.test"} = node!(s, "blimp-blog")
    assert [%{severity: "warn"}] = attention(s, "blimp-blog")

    caddy = put_in(caddy, [:hosts, "a.test", :err_rps], 2.5)
    s = build(t, %{caddy: Fixtures.ok(caddy)})

    assert [%{severity: "alert", text: "Blimp blog: a.test answering 5xx at 2.50/s"}] =
             attention(s, "blimp-blog")
  end

  test "a failing source is an alert and its nodes say unknown", %{topology: t} do
    s = build(t, %{sites: Fixtures.failed("cannot list /sites: no such file or directory")})
    assert %{status: "unknown", reason: "sites source failing"} = node!(s, "site-deciduous")

    assert %{
             severity: "alert",
             text: "sites source failing: cannot list /sites: no such file or directory"
           } =
             Enum.find(s.attention, &(&1.node == nil))

    s = build(t, %{caddy: Fixtures.failed("connection refused")})
    assert node!(s, "internet").status == "unknown"

    assert node!(s, "blimp-blog").hosts == [
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

    assert Enum.find(s.edges, &(&1.id == "internet>caddy")).rate == nil
  end

  test "a failing access source is an alert and no node says unknown for it", %{topology: t} do
    reason = "cannot open /caddy-logs/access.log: no such file or directory"
    ok = build(t, %{})
    s = build(t, %{access: Fixtures.failed(reason)})

    assert %{node: nil, severity: "alert", text: "access source failing: #{reason}"} in s.attention

    for n <- s.nodes, n.id != "soldat" do
      assert {n.id, n.status, n.reason} == {n.id, node!(ok, n.id).status, node!(ok, n.id).reason}
    end

    assert node!(s, "soldat").status in ["idle", "working"]
    assert attention(s, "soldat") == attention(ok, "soldat")
  end

  test "a static site whose directory is missing is down", %{topology: t} do
    s = build(t, %{sites: Fixtures.ok(%{})})

    assert %{status: "down", reason: "no directory deciduous in SITES_DIR"} =
             node!(s, "site-deciduous")
  end

  test "a static site whose directory cannot be read is unknown, alone", %{topology: t} do
    unreadable = %{
      bytes: nil,
      files: nil,
      newest_mtime: nil,
      error: "could not list directory \"/sites/deciduous\": permission denied"
    }

    s = build(t, %{sites: Fixtures.ok(%{"deciduous" => unreadable})})

    assert %{status: "unknown", reason: "site directory unreadable"} = node!(s, "site-deciduous")

    assert Enum.any?(
             s.attention,
             &(&1.node == "site-deciduous" and &1.text =~ "permission denied")
           )

    assert s.sources.sites.ok
  end

  test "OOM killed", %{topology: t, docker: d} do
    d =
      with_container(
        d,
        "blog-app-1",
        &inspect_set(%{&1 | state: "exited"}, %{
          running: false,
          status: "exited",
          oom_killed: true,
          exit_code: 137
        })
      )

    assert %{status: "down", reason: "OOM killed"} =
             node!(build(t, %{docker: Fixtures.ok(d)}), "app")
  end

  test "a failing report is a warning and never a status", %{topology: t} do
    ok = build(t, %{})

    s =
      build(t, %{
        reports: Fixtures.ok(%{"app" => %{ok: false, error: "answered 401", at: nil}})
      })

    assert attention(s, "app") -- attention(ok, "app") == [
             %{node: "app", severity: "warn", text: "Phoenix app report failing: answered 401"}
           ]

    for n <- s.nodes do
      assert {n.id, n.status, n.reason} == {n.id, node!(ok, n.id).status, node!(ok, n.id).reason}
    end

    assert ObsFactor.Rules.report("Blog", nil) == []
    assert ObsFactor.Rules.report("Blog", %{ok: true}) == []

    assert ObsFactor.Rules.report("Phoenix blog", %{ok: false, error: "connection refused"}) ==
             [{"warn", "Phoenix blog report failing: connection refused"}]
  end

  test "a down node whose report also fails says both", %{topology: t, docker: d} do
    d =
      with_container(
        d,
        "blog-app-1",
        &inspect_set(%{&1 | state: "exited"}, %{running: false, status: "exited", exit_code: 1})
      )

    s =
      build(t, %{
        docker: Fixtures.ok(d),
        reports: Fixtures.ok(%{"app" => %{ok: false, error: "host not found", at: nil}})
      })

    assert node!(s, "app").status == "down"

    assert Enum.map(attention(s, "app"), &{&1.severity, &1.text}) == [
             {"alert", "Phoenix app: exited (code 1)"},
             {"warn", "Phoenix app report failing: host not found"}
           ]
  end

  describe "a cluster's members side by side" do
    defp m(name, sees, opts \\ []) do
      conns =
        Enum.map(sees, fn other ->
          %{node: other, kind: "visible", in_bytes: 1, out_bytes: 1, send_queue_bytes: opts[:queue] || 0, in_bps: nil, out_bps: nil}
        end)

      %{ok: Keyword.get(opts, :ok, true), cluster: %{node: name, distributed: true, connections: conns, globals: opts[:globals] || []}}
    end

    test "a full mesh, or one node, says nothing" do
      assert ObsFactor.Rules.cluster("M", [m("a", ~w(b c)), m("b", ~w(a c)), m("c", ~w(a b))]) == []
      assert ObsFactor.Rules.cluster("M", [m("a", [])]) == []
      assert ObsFactor.Rules.cluster("M", nil) == []
    end

    test "one side listing the other is a partial partition; neither is not connected" do
      alerts = ObsFactor.Rules.cluster("M", [m("a", ~w(b c)), m("b", ~w(c)), m("c", ~w(a b))])
      assert alerts == [{"alert", "M: a lists b, which does not list it back (a partial partition)"}]

      assert [{"alert", "M: a and b are not connected"}] =
               ObsFactor.Rules.cluster("M", [m("a", ~w(c)), m("b", ~w(c)), m("c", ~w(a b))])
    end

    test "a node whose report failed is not counted as disconnected" do
      assert ObsFactor.Rules.cluster("M", [m("a", ~w(b)), m("b", ~w(a)), m("c", [], ok: false)]) == []
    end

    test "a deep send queue warns, and two homes for one global is an alert" do
      g = fn home -> [%{name: "Marginalia.Runs", node: home}] end
      alerts = ObsFactor.Rules.cluster("M", [m("a", ~w(b), queue: 5_000_000, globals: g.("a")), m("b", ~w(a), globals: g.("b"))])
      assert {"warn", "M: 4.8 MB queued on a for b"} in alerts
      assert {"alert", "M: the nodes disagree where Marginalia.Runs lives (a, b)"} in alerts
    end
  end

end
