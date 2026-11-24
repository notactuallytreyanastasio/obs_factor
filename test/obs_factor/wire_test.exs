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
        "distributed" => true,
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

  test "a restart is still news when the report was unreadable for the tick in between" do
    gone = %{"nodes" => [%{"id" => "marginalia", "label" => "Marginalia", "kind" => "app", "inside" => %{"ok" => false, "error" => "connection refused"}}]}
    {[], st} = Wire.observe(Wire.new(), snap(two()), @t)
    {[], st} = Wire.observe(st, gone, @t + 5_000)
    {items, _} = Wire.observe(st, snap(two([up: 4], up: 4)), @t + 10_000)
    assert "marginalia@.0.10 restarted" in heads(items) and "marginalia@.0.12 restarted" in heads(items)
    refute Enum.any?(items, &(&1.kind in ["joined", "left"]))
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

  describe "standing conditions" do
    defp three(reds10), do: [member("10", r: %{"reductions" => reds10}), member("12"), member("20")]

    test "a node 10x the others' median is news on the very first tick, and once" do
      {items, st} = Wire.observe(Wire.new(), snap(three(1_000_000.0)), @t)
      assert [%{kind: "outlier", member: "marginalia@172.18.0.10", head: "reductions 1,000,000/s: 167x the BEAM median"}] = items
      {[], st} = Wire.observe(st, snap(three(1_000_000.0)), @t + 5_000)
      # it ends, and when it starts again it is news again
      {[], st} = Wire.observe(st, snap(three(6000.0)), @t + 10_000)
      {[%{kind: "outlier"}], _} = Wire.observe(st, snap(three(900_000.0)), @t + 80_000)
    end

    test "a node far above its own normal, once the normal is known" do
      st =
        Enum.reduce(0..70, Wire.new(), fn i, st ->
          {_, st} = Wire.observe(st, snap(two([r: %{"reductions" => 60_000.0 + rem(i, 3) * 100}])), @t + i * 5_000)
          st
        end)

      {items, st} = Wire.observe(st, snap(two([r: %{"reductions" => 400_000.0}])), @t + 71 * 5_000)
      assert [%{kind: "anomaly", head: "reductions 400,000/s: " <> _}] = Enum.filter(items, &(&1.kind == "anomaly"))
      {items, _} = Wire.observe(st, snap(two([r: %{"reductions" => 410_000.0}])), @t + 72 * 5_000)
      assert Enum.filter(items, &(&1.kind == "anomaly")) == []
    end
  end

  describe "containers" do
    defp with_container(s, up, restarts, image) do
      update_in(s, ["nodes", Access.at(0)], &Map.merge(&1, %{"container" => %{"uptime_s" => up, "restarts" => restarts}, "facts" => [%{"label" => "image", "value" => image}]}))
    end

    test "started again is a deploy (or a manual restart), restarted by the policy is a crash, a new image is named" do
      base = with_container(snap(two()), 5000, 0, "blog-app:1")
      assert [%{kind: "deploy", head: "container started again"}] = run(base, with_container(snap(two()), 3, 0, "blog-app:1"))
      assert [%{kind: "crash", sev: "alert"}] = run(base, with_container(snap(two()), 3, 1, "blog-app:1"))
      assert [%{kind: "deploy", head: "deployed blog-app:2"}] = run(base, with_container(snap(two()), 3, 0, "blog-app:2"))
    end
  end

  test "metrics carry the hottest and biggest process, and each link's traffic" do
    boxes = %{{"marginalia", "10"} => %{top: [], hot: [%{"registered_name" => "Marginalia.Runs", "reductions_per_s" => 42_000}], big: [%{"registered_name" => ":code_server", "memory" => 9_000_000}]}}
    m = Wire.metrics(snap(two([sendq: 10])), boxes)["beam:marginalia@172.18.0.10"]
    assert %{hot_name: "Marginalia.Runs", hot_reds: 42_000, big_name: ":code_server", big_mem: 9_000_000} = m
    assert m.links == %{"marginalia@172.18.0.12" => [1.0, 10]}
  end

  describe "the review's findings (2026-11-24), each a regression test" do
    defp down(s), do: update_in(s, ["nodes", Access.at(0), "inside"], fn _ -> %{"ok" => false, "error" => "connection refused"} end)

    defp contained(s, up, restarts),
      do: update_in(s, ["nodes", Access.at(0)], &Map.merge(&1, %{"container" => %{"uptime_s" => up, "restarts" => restarts}, "facts" => [%{"label" => "image", "value" => "m:1"}]}))

    test "a crash is still a crash when the report was unreadable for the tick in between" do
      {_, st} = Wire.observe(Wire.new(), contained(snap(two()), 5000, 0), @t)
      # the container is read even while the report is not: the crash is
      # news on the unreadable tick itself, and not again after
      {items, st} = Wire.observe(st, down(contained(snap(two()), 2, 1)), @t + 5_000)
      assert Enum.any?(items, &(&1.kind == "crash"))
      {items, _} = Wire.observe(st, contained(snap(two([up: 7], up: 7)), 7, 1), @t + 10_000)
      refute Enum.any?(items, &(&1.kind == "crash"))
    end

    test "an app's old errors and streams are not news again after one unreadable tick" do
      e = %{"level" => "error", "name" => "X", "at" => "2026-11-23T21:33:35Z", "message" => "boom"}
      s = fn -> snap(two(), events: [e], streams: [%{"kind" => "db.query", "name" => "R", "rate" => 0.2, "err_rate" => 0.1, "avg_ms" => 300.0}]) end
      {_, st} = Wire.observe(Wire.new(), s.(), @t)
      {_, st} = Wire.observe(st, down(s.()), @t + 5_000)
      {items, _} = Wire.observe(st, s.(), @t + 70_000)
      refute Enum.any?(items, &(&1.kind in ["error", "failing", "slowq"]))
    end

    test "two outliers on one member in one tick are both said" do
      three = [member("10", g: %{"memory.total" => 3_000_000_000, "memory.binary" => 2_500_000_000}), member("12"), member("20")]
      {items, _} = Wire.observe(Wire.new(), snap(three), @t)
      assert Enum.sort(Enum.map(items, & &1.head) |> Enum.map(&hd(String.split(&1, " ")))) == ["binary", "memory"]
    end

    test "apps without distribution are told apart by their node id, not nonode@nohost" do
      solo = fn id -> %{"id" => id, "label" => id, "kind" => "app", "inside" => %{"ok" => true, "runtime" => %{"kind" => "beam", "gauges" => %{"process.count" => 1}}, "cluster" => %{"node" => "nonode@nohost", "distributed" => false}}} end
      m = Wire.metrics(%{"nodes" => [solo.("a"), solo.("b")]})
      assert Map.has_key?(m, "beam:a") and Map.has_key?(m, "beam:b")
    end

    test "a member whose own read failed for a tick is not 'left', and its restart is still news" do
      failed = %{"ok" => false, "address" => "12", "error" => "timeout"}
      {_, st} = Wire.observe(Wire.new(), snap(two()), @t)
      {items, st} = Wire.observe(st, snap([member("10", peers: ["12"]), failed]), @t + 5_000)
      refute Enum.any?(items, &(&1.kind == "left"))
      {items, _} = Wire.observe(st, snap(two([], up: 3)), @t + 10_000)
      assert "marginalia@.0.12 restarted" in heads(items)
      refute Enum.any?(items, &(&1.kind == "joined"))
    end

    test "baselines of members not seen for an hour are let go" do
      {_, st} = Wire.observe(Wire.new(), snap(two()), @t)
      assert Enum.any?(Map.keys(st.base), fn {k, _} -> k == "marginalia@172.18.0.12" end)
      {_, st} = Wire.observe(st, snap([member("10")]), @t + 3_700_000)
      refute Enum.any?(Map.keys(st.base), fn {k, _} -> k == "marginalia@172.18.0.12" end)
      refute Map.has_key?(st.members, "marginalia@172.18.0.12")
    end
  end

  test "a one-node app whose node name changed was replaced, not joined and left" do
    one = fn host, up -> %{"nodes" => [%{"id" => "app", "label" => "Blog", "kind" => "app", "inside" => %{"ok" => true, "runtime" => %{"kind" => "beam", "uptime_s" => up, "gauges" => %{}}, "cluster" => %{"node" => "blog@#{host}", "distributed" => true}}}]} end
    {_, st} = Wire.observe(Wire.new(), one.("aaa", 9000), @t)
    {items, _} = Wire.observe(st, one.("bbb", 3), @t + 5_000)
    assert [%{kind: "restart", head: "Blog replaced: blog@aaa → blog@bbb", text: "a new node took the old one's place after 2h 30m up"}] = items
  end
end
