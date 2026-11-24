defmodule ObsFactor.EvidenceTest do
  @moduledoc """
  Evidence at the moment, with a fake observer engine (`FakeProxy`) and a
  real Postgres (OBJECTIVES_TEST_PG_URL): a wire item about a Marginalia
  member makes one capture of that member's top processes, ETS, tables,
  LiveViews and events, stored and linked to the item's tape_wire id; a
  second item within the minute is linked to it, not captured again; it
  reads back over the `evidence` channel and into the writeup.
  """
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.{Evidence, Tape, Writeup}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  defmodule FakeProxy do
    @moduledoc "Answers like the observer engine; tells the test every call."
    def call("GET", app, path, params, opts) do
      send(:evidence_test, {:proxy, app, path, params, opts[:member]})

      case {app, path, params["sort"]} do
        {"down", _, _} ->
          {502, %{"error" => "172.18.0.99:9568: connection refused"}}

        {_, ["procs"], sort} ->
          rows =
            for i <- 1..12 do
              %{"pid" => "0.#{i}.0", "registered_name" => if(i == 1, do: "Marginalia.Ingest"), "initial_call" => "Elixir.Marginalia.Worker.init/1",
                "current_function" => "Elixir.Postgrex.Protocol.recv/3", "status" => "running", "memory" => 1_000_000 - i,
                "message_queue_len" => if(sort == "message_queue_len", do: 500 - i, else: 0), "reductions" => 10_000 - i,
                "reductions_per_s" => if(params["interval_ms"] == "500", do: 6_000_000 - i * 1000), "links" => 3, "supervisor?" => false}
            end

          # the engine honours limit; a fake that did not would hide a bug
          {200, %{"procs" => Enum.take(rows, String.to_integer(params["limit"])), "node" => "marginalia@x", "took_ms" => 501.0}}

        {_, ["ets"], _} ->
          {200, %{"tables" => for(i <- 1..30, do: %{"name" => ":t#{i}", "memory_bytes" => 1000 - i, "size" => i}), "count" => 30, "node" => "m"}}
      end
    end
  end

  @t 1_790_000_000_000

  defp member(addr, tables) do
    %{"ok" => true, "address" => addr, "runtime" => %{"kind" => "beam"},
      "cluster" => %{"distributed" => true, "node" => "marginalia@#{addr}"},
      "tables" => tables, "liveviews" => %{"total" => 2, "views" => [%{"view" => "MarginaliaWeb.ReadLive", "alive" => 2}]}}
  end

  defp snap do
    %{
      "nodes" => [
        %{"id" => "marginalia", "label" => "Marginalia",
          "inside" => %{"ok" => true, "runtime" => %{"kind" => "beam"},
                        "events" => for(i <- 1..25, do: %{"level" => "error", "name" => "Marginalia.Ingest", "message" => "boom #{i}"}),
                        "tables" => [%{"table" => "all members"}],
                        "members" => [member("172.18.0.10", [%{"table" => "links", "total_ms" => 900.0}]), member("172.18.0.12", [%{"table" => "runs"}]),
                                      %{"ok" => false, "address" => "172.18.0.13"}]}},
        %{"id" => "blog", "label" => "Blog", "inside" => %{"ok" => true, "runtime" => %{"kind" => "beam"}, "events" => [], "tables" => [], "liveviews" => nil, "members" => nil}},
        %{"id" => "down", "label" => "Down", "inside" => %{"ok" => true, "events" => []}},
        %{"id" => "pg", "label" => "Postgres", "inside" => nil}
      ]
    }
  end

  defp item(at, app, member, kind, head),
    do: %{at: at, app: app, label: String.capitalize(app), member: member, kind: kind, sev: "warn", head: head, text: "detail"}

  # ---- what triggers, which BEAM ---------------------------------------------

  test "what triggers a capture: the BEAM's own trouble and Repo streams failing or surging" do
    for k <- ~w(outlier anomaly crash restart mailbox runq), do: assert(Evidence.trigger?(item(@t, "a", nil, k, "x")))
    assert Evidence.trigger?(item(@t, "a", nil, "failing", "db.query Marginalia.Repo failing 5%"))
    refute Evidence.trigger?(item(@t, "a", nil, "failing", "http.route GET /x failing 5%"))
    assert Evidence.trigger?(item(@t, "a", nil, "surge", "Repo queries 2 → 250/s"))
    refute Evidence.trigger?(item(@t, "a", nil, "surge", "LiveView mounts 2 → 25/s"))
    for k <- ~w(error warning joined left deploy commits leader), do: refute(Evidence.trigger?(item(@t, "a", nil, k, "x")))
  end

  test "an item names its member; an app-wide one is every member that answered" do
    s = snap()
    assert [%{address: "172.18.0.12", member: "marginalia@172.18.0.12"}] = Evidence.targets(item(@t, "marginalia", "marginalia@172.18.0.12", "outlier", "x"), s)
    assert ["172.18.0.10", "172.18.0.12"] = Evidence.targets(item(@t, "marginalia", nil, "surge", "Repo queries 1 → 9/s"), s) |> Enum.map(& &1.address)
    assert [%{address: nil, member: "blog"}] = Evidence.targets(item(@t, "blog", "blog", "runq", "x"), s)
    assert [%{address: nil, node: nil}] = Evidence.targets(item(@t, "gone", nil, "crash", "x"), s)
  end

  # ---- one capture ---------------------------------------------------------------

  test "a capture: top 10 three ways, the hottest over 500 ms, ETS, the member's tables, events" do
    Process.register(self(), :evidence_test)
    [t] = Evidence.targets(item(@t, "marginalia", "marginalia@172.18.0.10", "outlier", "x"), snap())
    body = Evidence.capture(t, FakeProxy)

    assert_received {:proxy, "marginalia", ["procs"], %{"sort" => "reductions", "interval_ms" => "500", "limit" => "10"}, "172.18.0.10"}
    assert_received {:proxy, "marginalia", ["procs"], %{"sort" => "memory"}, "172.18.0.10"}
    assert_received {:proxy, "marginalia", ["procs"], %{"sort" => "message_queue_len"}, "172.18.0.10"}
    assert_received {:proxy, "marginalia", ["ets"], %{}, "172.18.0.10"}

    assert length(body["procs"]["reductions"]) == 10
    assert %{"registered_name" => "Marginalia.Ingest", "current_function" => "Elixir.Postgrex.Protocol.recv/3",
             "initial_call" => "Elixir.Marginalia.Worker.init/1", "reductions_per_s" => 5_999_000} = hd(body["procs"]["reductions"])
    refute Map.has_key?(hd(body["procs"]["memory"]), "links")
    assert length(body["ets"]) == 10
    assert body["tables"] == [%{"table" => "links", "total_ms" => 900.0}]
    assert body["liveviews"]["total"] == 2
    assert length(body["events"]) == 20
    assert body["errors"] == []
  end

  test "against the real engine (this VM, in-process): names, current functions, reductions/s over 500 ms" do
    t = %{app: "observer", member: nil, address: nil, node: %{"id" => "observer", "inside" => %{"ok" => true, "events" => []}}}
    started = System.monotonic_time(:millisecond)
    body = Evidence.capture(t)
    assert body["errors"] == []
    # the reductions read sleeps 500 ms on the node; the other three run beside it
    assert System.monotonic_time(:millisecond) - started in 500..2_000
    hot = body["procs"]["reductions"]
    assert length(hot) == 10 and Enum.all?(hot, &is_integer(&1["reductions_per_s"]))
    assert Enum.all?(body["procs"]["memory"], &(is_binary(&1["current_function"]) and is_binary(&1["pid"])))
    assert Enum.any?(body["procs"]["memory"], &is_binary(&1["registered_name"]))
    assert [%{"name" => _, "memory_bytes" => m} | _] = body["ets"]
    assert is_integer(m) and length(body["ets"]) == 10
  end

  test "what the engine would not say is in errors, by name; no report means no engine" do
    Process.register(self(), :evidence_test)
    [t] = Evidence.targets(item(@t, "down", nil, "crash", "x"), snap())
    body = Evidence.capture(t, FakeProxy)
    assert body["procs"] == %{} and body["ets"] == []
    assert "procs by reductions: 172.18.0.99:9568: connection refused" in body["errors"]
    assert "ets: 172.18.0.99:9568: connection refused" in body["errors"]

    [t] = Evidence.targets(item(@t, "pg", nil, "crash", "x"), snap())
    assert %{"errors" => ["pg has no report, so no observer engine: only the snapshot was kept"]} = Evidence.capture(t, FakeProxy)
    refute_received {:proxy, "pg", _, _, _}
  end

  # ---- stored, rate-limited, read back ---------------------------------------------

  describe "with a tape" do
    setup do
      db = Tape.db()
      start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
      Postgrex.query!(db, "DROP TABLE IF EXISTS wire_evidence_links, wire_evidence, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
      start_supervised!({ObsFactor.Objectives, db: db})
      tape_topic = "evidence_tape_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, tape_topic)
      start_supervised!({Tape, db: db, topic: tape_topic, thin_first_ms: 3_600_000})
      _ = :sys.get_state(Tape)
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, Evidence.topic())
      Process.register(self(), :evidence_test)
      start_supervised!({Evidence, db: db, proxy: FakeProxy, snapshot: &snap/0, thin_first_ms: 3_600_000})

      t0 = System.system_time(:millisecond) - 60_000

      record = fn at, wire ->
        s = %{attention: [], nodes: [%{id: "marginalia", label: "Marginalia", kind: "app", status: "working", hosts: []}]}
        Tape.record(at, Jason.encode!(s), Tape.summary(s, %{}, %{"beam:marginalia@172.18.0.10" => %{app: "marginalia", procs: 900, reds: 6.0e6}}, wire))
        assert_receive {:tape_frame, %{at: ^at}}, 2_000
      end

      %{db: db, t0: t0, record: record}
    end

    test "one capture per BEAM per minute, linked to the tape_wire id; a burst is linked, not captured again", %{db: db, t0: t0, record: record} do
      a = item(t0, "marginalia", "marginalia@172.18.0.10", "outlier", "reductions 6,000,000/s: 1000x the BEAM median")
      b = item(t0 + 5_000, "marginalia", "marginalia@172.18.0.10", "runq", "run queue 9 on 4 schedulers")
      quiet = item(t0 + 5_000, "marginalia", nil, "joined", "marginalia@.0.13 joined")

      record.(t0, [a])
      Evidence.notice([a])
      assert_receive {:evidence, %{id: id, member: "marginalia@172.18.0.10", address: "172.18.0.10", hot: %{name: "Marginalia.Ingest", reductions_per_s: 5_999_000}, links: [l]}}, 3_000
      assert %{kind: "outlier", wire_id: wid, at: ^t0} = l
      assert is_integer(wid)
      assert {:ok, %{rows: [[^wid]]}} = Postgrex.query(db, "SELECT id FROM tape_wire WHERE kind = 'outlier'", [])

      # five seconds later, the same member: linked to the minute's capture
      record.(t0 + 5_000, [b, quiet])
      Evidence.notice([b, quiet])
      assert_receive {:evidence, %{id: ^id, links: [_, %{kind: "runq", wire_id: wid2, captured_before_ms: before}]}}, 3_000
      assert is_integer(wid2) and before >= 0

      # the engine was asked once: four calls (three procs, one ets), not eight
      calls = collect_calls()
      assert length(calls) == 4
      assert {:ok, %{rows: [[1, 2]]}} = Postgrex.query(db, "SELECT (SELECT count(*) FROM wire_evidence)::int, (SELECT count(*) FROM wire_evidence_links)::int", [])

      # read back: by id, by wire id, the index of a range
      assert {:ok, %{id: ^id, body: %{"procs" => %{"reductions" => [_ | _]}, "events" => ev}}} = Evidence.get(id)
      assert length(ev) == 20
      assert {:ok, %{id: ^id}} = Evidence.for_wire(wid2)
      assert :none = Evidence.for_wire(wid2 + 1000)
      assert {:ok, [%{id: ^id, links: [_, _]}]} = Evidence.index(t0 - 1, t0 + 10_000)
      assert {:ok, []} = Evidence.index(t0 + 6_000, t0 + 10_000)
    end

    test "an app-wide Repo surge is captured on each member that answered", %{t0: t0, record: record} do
      s = item(t0, "marginalia", nil, "surge", "Repo queries 2 → 250/s")
      record.(t0, [s])
      Evidence.notice([s])
      assert_receive {:evidence, %{address: a1}}, 3_000
      assert_receive {:evidence, %{address: a2}}, 3_000
      assert Enum.sort([a1, a2]) == ["172.18.0.10", "172.18.0.12"]
    end

    test "nothing to capture: no cast reaches the engine", %{t0: t0} do
      Evidence.notice([item(t0, "marginalia", nil, "joined", "x joined")])
      _ = :sys.get_state(Evidence)
      refute_receive {:proxy, _, _, _, _}, 200
    end

    test "over the channel, and in the writeup's Out of the ordinary", %{t0: t0, record: record} do
      a = item(t0, "marginalia", "marginalia@172.18.0.10", "outlier", "reductions 6,000,000/s: 1000x the BEAM median")
      {:ok, %{}, socket} = subscribe_and_join(authed_socket("ev"), ObsFactorWeb.EvidenceChannel, "evidence")

      record.(t0, [a])
      Evidence.notice([a])
      assert_push "captured", %{id: id, links: [%{wire_id: wid}]}, 3_000

      ref = push(socket, "index", %{"from" => t0 - 1000, "to" => t0 + 1000})
      assert_reply ref, :ok, %{evidence: [%{id: ^id}]}
      ref = push(socket, "get", %{"wire_id" => wid})
      assert_reply ref, :ok, %{evidence: %{id: ^id, body: %{"ets" => [_ | _]}}}
      ref = push(socket, "get", %{"id" => id + 99})
      assert_reply ref, :error, %{error: "no evidence for that"}
      ref = push(socket, "index", %{"from" => 2, "to" => 1})
      assert_reply ref, :error, %{error: "index needs from and to" <> _}

      record.(t0 + 5_000, [])
      {:ok, w} = Writeup.build(from: t0 - 1000, to: t0 + 6_000, sections: ["beam"])
      assert w.markdown =~ "### Out of the ordinary"
      assert w.markdown =~ "reductions 6,000,000/s: 1000x the BEAM median\n  - evidence taken at "
      assert w.markdown =~ " on marginalia@172.18.0.10:\n    - hottest: `Marginalia.Ingest` in `Postgrex.Protocol.recv/3` 5,999,000 reductions/s; `Marginalia.Worker.init/1 0.2.0` in"
      assert w.markdown =~ "\n    - biggest mailbox: `Marginalia.Ingest` in `Postgrex.Protocol.recv/3` 499 messages"
    end
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:proxy, _, _, _, _} = c -> collect_calls([c | acc])
    after
      100 -> acc
    end
  end
end
