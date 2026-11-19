defmodule ObsFactor.HistoryTest do
  use ExUnit.Case, async: true

  alias ObsFactor.{Fixtures, History, Snapshot}

  setup do
    {:ok, server: start_supervised!({History, name: nil})}
  end

  test "records snapshot metrics and answers per node", %{server: h} do
    sources = Fixtures.sources()

    {snap, _} =
      Snapshot.build(Fixtures.topology(), sources, Snapshot.empty_memory(), Fixtures.now())

    metrics = History.metrics(snap, sources)

    assert metrics["db"].connections == 96
    assert metrics["host-disk"].disk_used_pct == 86.4

    t0 = 1_795_041_300_000
    History.record(h, t0, metrics)
    History.record(h, t0 + 5_000, metrics)

    assert {:ok, series} = History.query(h, "blimp-blog", "5s")
    cpu = Enum.find(series, &(&1.key == "cpu_cores"))
    assert cpu.label == "CPU" and cpu.unit == "cores"
    assert [[^t0, v], [_, v]] = cpu.points
    assert_in_delta v, 0.0067, 0.0001

    assert :unknown_node = History.query(h, "nope", "5s")
  end

  test "4xx, bytes out and in flight for a node with hosts and for the proxy", %{server: h} do
    sources = Fixtures.sources()

    {snap, _} =
      Snapshot.build(Fixtures.topology(), sources, Snapshot.empty_memory(), Fixtures.now())

    metrics = History.metrics(snap, sources)

    assert %{rps_4xx: 0.4, out_bps: 12_000.0, in_flight: 2.0} = metrics["blimp-blog"]
    # The proxy sums a.test and b.test.
    assert %{rps_4xx: 0.4, out_bps: 12_000.0, in_flight: 2.0} = metrics["caddy"]
    assert metrics["site-deciduous"].rps_4xx == 0.0
    assert metrics["site-deciduous"].in_flight == 0.0

    # Nodes without hosts have none of them.
    for id <- ["db", "marginalia", "host-cpu", "internet"],
        key <- [:rps_4xx, :out_bps, :in_flight] do
      refute Map.has_key?(metrics[id], key), "#{id} has #{key}"
    end

    t0 = 1_795_041_300_000
    History.record(h, t0, metrics)
    assert {:ok, series} = History.query(h, "blimp-blog", "5s")

    described = Map.new(series, &{&1.key, {&1.label, &1.unit, &1.points}})
    assert described["rps_4xx"] == {"4xx", "req/s", [[t0, 0.4]]}
    assert described["out_bps"] == {"Bytes out", "B/s", [[t0, 12_000.0]]}
    assert described["in_flight"] == {"In flight", "requests", [[t0, 2.0]]}

    assert Enum.map(series, & &1.key) ==
             ~w(rps err_rps rps_4xx avg_ms p95_ms out_bps in_flight cpu_cores mem_bytes net_rx_bps net_tx_bps)
  end

  test "p95 where the log has requests, requests/s for a path-route node", %{server: h} do
    topology = Fixtures.topology()
    sources = Fixtures.sources()
    {snap, _} = Snapshot.build(topology, sources, Snapshot.empty_memory(), Fixtures.now())
    metrics = History.metrics(snap, sources)

    assert %{p95_ms: 251.03, rps: 2.0} = metrics["soldat"]
    assert metrics["blimp-blog"].p95_ms == 7.84
    # No requests in the log: no p95 series; not a path-route node: no rps from the log.
    refute Map.has_key?(metrics["app"], :p95_ms)
    refute Map.has_key?(metrics["marginalia"], :rps)

    failing = Fixtures.sources(%{access: Fixtures.failed("ACCESS_LOG is not set")})
    {dark, _} = Snapshot.build(topology, failing, Snapshot.empty_memory(), Fixtures.now())
    unknown = History.metrics(dark, failing)

    # The path-route node keeps its series, with a hole in it.
    assert unknown["soldat"].rps == nil
    refute Map.has_key?(unknown["soldat"], :p95_ms)
    assert unknown["blimp-blog"].rps == 2.0

    t0 = 1_795_041_300_000
    History.record(h, t0, metrics)
    History.record(h, t0 + 5_000, unknown)

    assert {:ok, series} = History.query(h, "soldat", "5s")
    described = Map.new(series, &{&1.key, {&1.label, &1.unit, &1.points}})
    assert described["p95_ms"] == {"p95", "ms", [[t0, 251.03], [t0 + 5_000, nil]]}
    assert described["rps"] == {"Requests", "req/s", [[t0, 2.0], [t0 + 5_000, nil]]}
  end

  test "a sum with one unknown host is unknown" do
    known = %{
      host: "a.test",
      rps: 1.0,
      err_rps: 0.0,
      avg_ms: 4.0,
      codes: %{"2xx" => 0.5, "3xx" => 0.0, "4xx" => 0.5, "5xx" => 0.0, "other" => 0.0},
      in_bps: 10.0,
      out_bps: 900.0,
      in_flight: 1
    }

    # Rates unknown (first scrape), the gauge known.
    fresh = %{
      known
      | host: "b.test",
        rps: nil,
        err_rps: nil,
        codes: nil,
        in_bps: nil,
        out_bps: nil
    }

    node = fn hosts -> %{id: "n", kind: "app", container: nil, hosts: hosts} end

    both = History.metrics(%{nodes: [node.([known, %{known | host: "c.test"}])]}, %{})["n"]
    assert %{rps_4xx: 1.0, out_bps: 1800.0, in_flight: 2.0} = both

    holed = History.metrics(%{nodes: [node.([known, fresh])]}, %{})["n"]
    assert %{rps: nil, rps_4xx: nil, out_bps: nil, in_flight: 2.0} = holed

    dark = History.metrics(%{nodes: [node.([known, %{fresh | in_flight: nil}])]}, %{})["n"]
    assert dark.in_flight == nil
  end

  test "minute buckets average and ignore nils", %{server: h} do
    t0 = 1_795_041_300_000
    History.record(h, t0, %{"n" => %{rps: 1.0, avg_ms: nil}})
    History.record(h, t0 + 5_000, %{"n" => %{rps: 3.0, avg_ms: nil}})
    assert {:ok, []} = History.query(h, "n", "1m")

    History.record(h, t0 + 60_000, %{"n" => %{rps: 10.0, avg_ms: 2.0}})
    assert {:ok, series} = History.query(h, "n", "1m")
    assert %{points: [[^t0, 2.0]]} = Enum.find(series, &(&1.key == "rps"))
    assert %{points: [[^t0, nil]]} = Enum.find(series, &(&1.key == "avg_ms"))
  end

  test "keeps one hour of 5 s points", %{server: h} do
    for i <- 0..799, do: History.record(h, i * 5_000, %{"n" => %{rps: i * 1.0}})
    {:ok, [%{points: points}]} = History.query(h, "n", "5s")
    assert length(points) == 720
    assert hd(points) == [80 * 5_000, 80.0]
  end

  test "what is inside: BEAM memory, processes, run queue, units", %{server: h} do
    topology = Fixtures.topology()
    sources = Fixtures.sources()
    {snap, _} = Snapshot.build(topology, sources, Snapshot.empty_memory(), Fixtures.now())
    metrics = History.metrics(snap, sources)

    assert %{beam_memory: 123_456_789, process_count: 812, run_queue: 0, units: 3} =
             metrics["app"]

    # A node without a report has none of them.
    for key <- [:beam_memory, :process_count, :run_queue, :units] do
      refute Map.has_key?(metrics["blimp-blog"], key)
    end

    # While the report fails, nothing is recorded for it: a gap, not a zero.
    failing =
      Fixtures.sources(%{
        reports: Fixtures.ok(%{"app" => %{ok: false, error: "timed out", at: nil}})
      })

    {snap, _} = Snapshot.build(topology, failing, Snapshot.empty_memory(), Fixtures.now())
    gap = History.metrics(snap, failing)
    refute Map.has_key?(gap["app"], :beam_memory)
    refute Map.has_key?(gap["app"], :units)

    t0 = 1_795_041_300_000
    History.record(h, t0, metrics)
    History.record(h, t0 + 5_000, gap)

    assert {:ok, series} = History.query(h, "app", "5s")
    described = Map.new(series, &{&1.key, {&1.label, &1.unit, &1.points}})

    assert described["beam_memory"] ==
             {"BEAM memory", "B", [[t0, 123_456_789], [t0 + 5_000, nil]]}

    assert described["process_count"] ==
             {"Processes", "processes", [[t0, 812], [t0 + 5_000, nil]]}

    assert described["run_queue"] == {"Run queue", "processes", [[t0, 0], [t0 + 5_000, nil]]}
    assert described["units"] == {"Units inside", "units", [[t0, 3], [t0 + 5_000, nil]]}
  end

  test "a runtime that is not a BEAM: only the gauges it has, and its units" do
    doc =
      Fixtures.report_doc()
      |> put_in(["runtime", "kind"], "node")
      |> put_in(["runtime", "gauges"], %{"memory.rss" => 5_000_000, "run_queue" => "idle"})
      |> update_in(["units"], &(&1 ++ [%{"kind" => "room", "name" => "lobby", "count" => 4}]))

    {:ok, reading} = ObsFactor.Reports.validate(doc)

    {data, _} =
      ObsFactor.Reports.step(ObsFactor.Reports.new_node(), {:ok, reading}, Fixtures.now_ms())

    sources = Fixtures.sources(%{reports: Fixtures.ok(%{"app" => data})})

    {snap, _} =
      Snapshot.build(Fixtures.topology(), sources, Snapshot.empty_memory(), Fixtures.now())

    app = History.metrics(snap, sources)["app"]
    assert app.units == 7

    for key <- [:beam_memory, :process_count, :run_queue] do
      refute Map.has_key?(app, key)
    end
  end

  test "what an app reports about its inside is not kept in the 24 h store" do
    averaged = History.average([%{"app" => %{beam_memory: 100, units: 3, rps: 2.0}}])
    assert History.drop_short_lived(averaged) == %{"app" => %{rps: 2.0}}
  end
end
