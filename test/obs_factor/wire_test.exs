defmodule ObsFactor.WireTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Wire

  @t 1_790_000_000_000

  # a member of a cluster as a report describes it (JSON: string keys)
  defp member(addr, opts \\ []) do
    peers = Keyword.get(opts, :peers, [])

    %{
      "ok" => true,
      "address" => addr,
      "runtime" => %{
        "kind" => "beam",
        "uptime_s" => Keyword.get(opts, :up, 1000),
        "gauges" =>
          Map.merge(
            %{"process.count" => 500, "run_queue" => 0, "schedulers.online" => 4, "scheduler.utilization" => 0.01,
              "memory.total" => 150_000_000, "memory.binary" => 20_000_000, "atom.count" => 50_000, "atom.limit" => 1_048_576},
            Keyword.get(opts, :g, %{})
          ),
        "rates" => Map.merge(%{"reductions" => 6000.0, "report.handler_errors" => 0.0}, Keyword.get(opts, :r, %{}))
      },
      "cluster" => %{
        "node" => "marginalia@172.18.0.#{addr}",
        "connections" =>
          for(p <- peers, do: %{"node" => "marginalia@172.18.0.#{p}", "out_bps" => 1.0, "send_queue_bytes" => Keyword.get(opts, :sendq, 0)}),
        "globals" => [%{"name" => "Marginalia.Runs", "node" => "marginalia@172.18.0.#{Keyword.get(opts, :leader, "10")}"}]
      }
    }
  end

  defp snap(members, opts \\ []) do
    %{
      "nodes" => [
        %{
          "id" => "marginalia",
          "label" => "Marginalia",
          "kind" => "app",
          "inside" => %{
            "ok" => true,
            "runtime" => %{"kind" => "beam"},
            "members" => members,
            "events" => Keyword.get(opts, :events, []),
            "streams" => Keyword.get(opts, :streams, [%{"kind" => "db.query", "name" => "Marginalia.Repo", "rate" => 0.2, "err_rate" => 0.0, "avg_ms" => 2.0}])
          }
        },
        %{"id" => "site", "label" => "a static site", "kind" => "static"}
      ]
    }
  end

  defp two(opts10 \\ [], opts12 \\ []),
    do: [member("10", Keyword.merge([peers: ["12"]], opts10)), member("12", Keyword.merge([peers: ["10"]], opts12))]

  defp run(s0, s1, boxes \\ %{}) do
    {[], st} = Wire.observe(Wire.new(), s0, @t)
    {items, _} = Wire.observe(st, s1, @t + 5_000, boxes)
    items
  end

  defp heads(items), do: Enum.map(items, & &1.head)

  test "the first tick only learns: what was already true is not news" do
    {items, _} = Wire.observe(Wire.new(), snap(two([g: %{"run_queue" => 9}])), @t)
    assert items == []
  end

  test "nothing changed, nothing said" do
    assert run(snap(two()), snap(two())) == []
  end

  test "a restart, a process jump and a run queue past the schedulers, on the member it happened on" do
    items = run(snap(two()), snap(two([], up: 3, g: %{"process.count" => 1300, "run_queue" => 9})))
    assert "marginalia@.0.12 restarted" in heads(items)
    assert "processes 500 → 1,300" in heads(items)
    assert "run queue 9 on 4 schedulers" in heads(items)
    assert Enum.all?(items, &(&1.member == "marginalia@172.18.0.12" and &1.app == "marginalia" and &1.at == @t + 5_000))
  end

  test "atoms climbing are a leak warning, an alarm past 80% of the limit" do
    [i] = run(snap(two()), snap(two(g: %{"atom.count" => 51_000})))
    assert i.head == "atoms +1,000" and i.sev == "warn"
    [i] = run(snap(two()), snap(two(g: %{"atom.count" => 900_000})))
    assert i.sev == "alert"
  end

  test "memory: a jump in binaries says so; small growth does not" do
    assert run(snap(two()), snap(two(g: %{"memory.binary" => 30_000_000}))) == []
    [i] = run(snap(two()), snap(two(g: %{"memory.binary" => 90_000_000})))
    assert i.kind == "binary" and i.head =~ "binary heap"
  end

  test "the cluster: a lost peer is a partition, a member gone is news, a moved global is a new leader" do
    items = run(snap(two()), snap([member("10", peers: [], leader: "12"), member("12", peers: [], leader: "12")]))
    assert "marginalia@.0.10 lost marginalia@.0.12" in heads(items)
    assert Enum.any?(items, &(&1.kind == "partition" and &1.sev == "alert"))
    assert "Marginalia.Runs moved marginalia@.0.10 → marginalia@.0.12" in heads(items)
    # one leader move is one item, however many members say so
    assert Enum.count(items, &(&1.kind == "leader")) == 1

    items = run(snap(two()), snap([member("10", peers: [])]))
    assert "marginalia@.0.12 left" in heads(items)
    items = run(snap([member("10")]), snap(two()))
    assert "marginalia@.0.12 joined" in heads(items)
  end

  test "a send queue backing up" do
    [i] = run(snap(two()), snap(two([sendq: 200_000])))
    assert i.head == "send queue to marginalia@.0.12 195 KB"
  end

  test "what the app logged: a new error, once, with where it came from" do
    e = %{"level" => "error", "name" => "Bandit.Pipeline", "at" => "2026-11-23T21:33:35Z", "message" => "** (ArgumentError) no ETS table\nstack", "by" => %{"name" => "GET /allowed-chats"}}
    [i] = run(snap(two()), snap(two(), events: [e]))
    assert i.kind == "error" and i.sev == "alert"
    assert i.head == "error in Bandit.Pipeline at GET /allowed-chats"
    assert i.text =~ "ArgumentError"
    # still in the report next tick: not news again
    assert run(snap(two(), events: [e]), snap(two(), events: [e])) == []
  end

  test "streams: failing, surging, slowing Repo queries" do
    s = fn rate, err, ms -> [%{"kind" => "db.query", "name" => "Marginalia.Repo", "rate" => rate, "err_rate" => err, "avg_ms" => ms}] end
    assert ["db.query Marginalia.Repo failing 5%"] = heads(run(snap(two(), streams: s.(0.2, 0.0, 2.0)), snap(two(), streams: s.(0.2, 0.05, 2.0))))
    assert ["Repo queries 0.2 → 9/s"] = heads(run(snap(two(), streams: s.(0.2, 0.0, 2.0)), snap(two(), streams: s.(9.0, 0.0, 2.0))))
    assert ["Repo queries 350 ms on average"] = heads(run(snap(two(), streams: s.(0.2, 0.0, 2.0)), snap(two(), streams: s.(0.2, 0.0, 350.0))))
  end

  test "a mailbox of 100 or more, from the observer engine; said once while it stays" do
    boxes = %{{"marginalia", "10"} => %{top: [%{"registered_name" => "Marginalia.Runs", "message_queue_len" => 1204}]}}
    [i] = run(snap(two()), snap(two()), boxes)
    assert i.head == "Marginalia.Runs holds 1,204 messages" and i.member == "marginalia@172.18.0.10"

    {_, st} = Wire.observe(Wire.new(), snap(two()), @t)
    {[_], st} = Wire.observe(st, snap(two()), @t + 5_000, boxes)
    {[], _} = Wire.observe(st, snap(two()), @t + 10_000, boxes)
  end

  test "the same kind of news about the same member at most once a minute" do
    {_, st} = Wire.observe(Wire.new(), snap(two()), @t)
    {[_], st} = Wire.observe(st, snap(two([], up: 3)), @t + 5_000)
    {[], st} = Wire.observe(st, snap(two([], up: 1)), @t + 10_000)
    {[_], _} = Wire.observe(st, snap(two([], up: 0)), @t + 75_000)
  end

  test "metrics: each member's BEAM numbers, keyed by node, with the leader's names and the biggest mailbox" do
    boxes = %{{"marginalia", "10"} => %{top: [%{"registered_name" => "Marginalia.Runs", "message_queue_len" => 7}]}}
    m = Wire.metrics(snap(two()), boxes)
    assert %{procs: 500, rq: 0, peers: 1, mbox: 7, mbox_name: "Marginalia.Runs", leads: ["Marginalia.Runs"], app: "marginalia"} = m["beam:marginalia@172.18.0.10"]
    assert %{leads: []} = m["beam:marginalia@172.18.0.12"]
    assert %{rate: 0.2, name: "Marginalia.Repo"} = m["repo:marginalia"]
    refute Map.has_key?(m, "beam:site")
  end
end
