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
end
