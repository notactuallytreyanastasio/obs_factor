defmodule ObsFactor.TopicsTest do
  # PubSub: from the report through the collector to the snapshot's
  # `inside`, onto the tape and the wire, and the observer feed views. The
  # real reporter and the observer's own VM are read for real.
  use ExUnit.Case, async: false

  alias ObsFactor.{Fixtures, Reports, Snapshot, Wire}
  alias ObsFactor.Feeds.ObserverViews

  @t 1_790_000_000_000
  @min 60_000

  defp server(name, subs, opts \\ []) do
    %{
      "name" => name,
      "adapter" => "Phoenix.PubSub.PG2",
      "keys" => "duplicate",
      "partitions" => 3,
      "topics" => Keyword.get(opts, :topics, 10),
      "subscriptions" => subs,
      "subscribers" => Keyword.get(opts, :subscribers, 5),
      "top" => Keyword.get(opts, :top, [%{"pattern" => "room:#", "topics" => 8, "subscriptions" => 12}, %{"pattern" => "lobby", "topics" => 1, "subscriptions" => 3}]),
      "patterns_cut" => 0,
      "counts_only" => nil,
      "walk_limit" => 100_000,
      "took_ms" => 0.2
    }
  end

  defp validated!(doc) do
    assert {:ok, r} = Reports.validate(doc)
    r
  end

  defp inside(data) do
    {s, _} =
      Snapshot.build(Fixtures.topology(), Fixtures.sources(%{reports: Fixtures.ok(%{"app" => data})}), Snapshot.empty_memory(), Fixtures.now())

    s |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("nodes") |> Enum.find(&(&1["id"] == "app")) |> Map.fetch!("inside")
  end

  defp read(doc) do
    {data, _} = Reports.step(Reports.new_node(), {:ok, validated!(doc)}, Fixtures.now_ms())
    data
  end

  describe "the report's pubsub, to the snapshot" do
    test "validated as sent; absent from an older reporter; a wrong shape is an error that names it" do
      r = validated!(Map.put(Fixtures.report_doc(), "pubsub", [server("Blog.PubSub", 15)]))

      assert [%{name: "Blog.PubSub", adapter: "Phoenix.PubSub.PG2", topics: 10, subscriptions: 15, subscribers: 5, partitions: 3,
                top: [%{pattern: "room:#", topics: 8, subscriptions: 12}, %{pattern: "lobby"} | _], counts_only: nil}] = r.pubsub

      assert validated!(Fixtures.report_doc()).pubsub == nil

      bad = fn doc -> elem(Reports.validate(doc), 1) end
      assert bad.(Map.put(Fixtures.report_doc(), "pubsub", %{})) == "pubsub is not a list"
      assert bad.(Map.put(Fixtures.report_doc(), "pubsub", [Map.delete(server("A", 1), "subscriptions")])) == "pubsub[0].subscriptions is missing"
      assert bad.(Map.put(Fixtures.report_doc(), "pubsub", [server("A", 1, top: [%{"pattern" => 3}])])) == "pubsub[0].top[0].pattern is not a string"

      # counts only: topics and subscribers unknown
      [s] = validated!(Map.put(Fixtures.report_doc(), "pubsub", [server("A", 200_000, topics: nil, subscribers: nil, top: []) |> Map.put("counts_only", "too many")])).pubsub
      assert %{topics: nil, subscribers: nil, top: [], counts_only: "too many"} = s
    end

    test "inside, per node; a cluster sums its members' servers by name and each member keeps its own" do
      single = inside(read(Map.put(Fixtures.report_doc(), "pubsub", [server("Blog.PubSub", 15)])))
      assert [%{"name" => "Blog.PubSub", "subscriptions" => 15, "top" => [%{"pattern" => "room:#", "topics" => 8} | _]}] = single["pubsub"]

      assert inside(read(Fixtures.report_doc()))["pubsub"] == nil

      a = read(Map.put(Fixtures.report_doc(), "pubsub", [server("Blog.PubSub", 15)]))
      b = read(Map.put(Fixtures.report_doc(), "pubsub", [server("Blog.PubSub", 5, topics: 4, top: [%{"pattern" => "lobby", "topics" => 1, "subscriptions" => 4}])]))
      down = %{ok: false, error: "connection refused", at: nil}
      inside = inside(Reports.combine([{"10.0.0.2", a}, {"10.0.0.3", b}, {"10.0.0.4", down}]))

      assert [%{"name" => "Blog.PubSub", "subscriptions" => 20, "topics" => 14, "subscribers" => 10, "top" => top}] = inside["pubsub"]
      assert top == [%{"pattern" => "room:#", "topics" => 8, "subscriptions" => 12}, %{"pattern" => "lobby", "topics" => 2, "subscriptions" => 7}]

      [m2, m3, m4] = inside["members"]
      assert [%{"subscriptions" => 15}] = m2["pubsub"]
      assert [%{"subscriptions" => 5}] = m3["pubsub"]
      assert %{"ok" => false, "pubsub" => nil} = m4
    end

    test "the real reporter, over HTTP, with a real Phoenix.PubSub" do
      start_supervised!({FactoryReport, app: :obs_factor, port: 0})
      start_supervised!(%{id: :ps, type: :supervisor, start: {Supervisor, :start_link, [[{Phoenix.PubSub, name: TopicsTest.PubSub}], [strategy: :one_for_one]]}})
      Phoenix.PubSub.subscribe(TopicsTest.PubSub, "room:user-1234")
      Phoenix.PubSub.subscribe(TopicsTest.PubSub, "room:user-99")

      assert {:ok, reading} = Reports.fetch("http://127.0.0.1:#{FactoryReport.port()}/report", nil)
      s = Enum.find(inside(read_reading(reading))["pubsub"], &(&1["name"] == "TopicsTest.PubSub"))
      assert %{"topics" => 2, "subscriptions" => 2, "subscribers" => 1, "top" => [%{"pattern" => "room:user-#", "topics" => 2, "subscriptions" => 2}]} = s

      # the observer's own: ObsFactor.PubSub with what the app subscribes
      own = ObsFactor.Topics.own()
      assert Enum.any?(own, &(&1["name"] == "ObsFactor.PubSub"))
    end
  end

  defp read_reading(reading) do
    {data, _} = Reports.step(Reports.new_node(), {:ok, reading}, Fixtures.now_ms())
    data
  end

  # ---- the wire ---------------------------------------------------------------

  # a snapshot as the wire reads it: one app on one node, and the observer
  defp snap(subs, opts \\ []) do
    %{
      "nodes" => [
        %{
          "id" => "blog",
          "label" => "Blog",
          "kind" => "app",
          "inside" => %{
            "ok" => true,
            "runtime" => %{"kind" => "beam", "gauges" => %{}, "rates" => %{}, "uptime_s" => 100},
            "pubsub" => [server("Blog.PubSub", subs, topics: Keyword.get(opts, :topics, 10))]
          }
        }
      ],
      "observer_pubsub" => [server("ObsFactor.PubSub", 30, topics: 12)]
    }
  end

  # ticks every 5 s from t0 for `minutes`, subscriptions from f.(minute)
  defp ticks(wire, t0, minutes, f) do
    Enum.reduce(0..(minutes * 12), {[], wire}, fn i, {acc, w} ->
      {items, w} = Wire.observe(w, snap(f.(i / 12)), t0 + i * 5_000)
      {acc ++ items, w}
    end)
  end

  describe "on the tape" do
    test "per member and server, and the observer's own" do
      m = Wire.metrics(snap(15))
      assert m["pubsub:blog:Blog.PubSub"] == %{app: "blog", member: "blog", server: "Blog.PubSub", topics: 10, subs: 15}
      assert m["pubsub:observer:ObsFactor.PubSub"] == %{app: "observer", member: "observer", server: "ObsFactor.PubSub", topics: 12, subs: 30}
      # beside the BEAM numbers, not instead of them
      assert Map.has_key?(m, "beam:blog")
    end
  end

  describe "on the wire" do
    test "subscriptions up every minute for 30 minutes and never down: a leak, said once" do
      {items, _} = ticks(Wire.new(), @t, 40, fn min -> 100 + floor(min * 2) end)
      leaks = Enum.filter(items, &(&1.kind == "pubsub" and &1.head =~ "subscriptions"))

      assert [leak] = leaks
      assert leak.app == "blog" and leak.sev == "warn" and leak.member == "blog"
      assert leak.head =~ ~r/^Blog\.PubSub subscriptions 1\d\d → 1\d\d, never down in 30 min$/
      assert leak.text =~ "a subscription leak on blog"
      assert leak.at >= @t + 30 * @min
    end

    test "growth that comes back down, or is too small, or stops for ten minutes, is not a leak" do
      saw = fn f -> ticks(Wire.new(), @t, 45, f) |> elem(0) |> Enum.filter(&(&1.kind == "pubsub")) end
      # down for a minute every 10 minutes
      assert saw.(fn min -> if rem(floor(min), 10) == 9, do: 50, else: 100 + floor(min * 2) end) == []
      # +10 over 40 minutes
      assert saw.(fn min -> 100 + floor(min / 4) end) == []
      # up, then flat from minute 12 on
      assert saw.(fn min -> 100 + floor(min(min, 12) * 5) end) == []
    end

    test "a leak that ends and starts again is said again" do
      {a, w} = ticks(Wire.new(), @t, 35, fn min -> 100 + floor(min * 2) end)
      {b, w} = ticks(w, @t + 36 * @min, 1, fn _ -> 10 end)
      {c, _} = ticks(w, @t + 38 * @min, 35, fn min -> 10 + floor(min * 2) end)
      count = fn items -> Enum.count(items, &(&1.kind == "pubsub")) end
      assert {count.(a), count.(b), count.(c)} == {1, 0, 1}
    end

    test "topics jumping by 50 and by half in one tick" do
      {[], w} = Wire.observe(Wire.new(), snap(15, topics: 40), @t)
      {[], w} = Wire.observe(w, snap(15, topics: 60), @t + 5_000)
      {[item], w} = Wire.observe(w, snap(15, topics: 130), @t + 10_000)
      assert %{kind: "pubsub", sev: "info", head: "Blog.PubSub topics 60 → 130", text: "+117% in one tick on blog"} = item
      # a minute later: the wire says one kind of thing about a member once a minute
      {[item], _} = Wire.observe(w, snap(15, topics: 500), @t + 75_000)
      assert item.sev == "warn"
    end
  end

  describe "observer feed views" do
    test "pubsub and pubsub:<server>:<topic>, and what is refused" do
      assert {:ok, {ObserverViews, {"observer", nil, ["pubsub"], %{"limit" => "1000"}}, 5_000}} =
               ObserverViews.resolve("observer:observer:-:pubsub")

      assert {:ok, {ObserverViews, {"observer", nil, ["pubsub"], %{"server" => "ObsFactor.PubSub", "topic" => "observer:observer:-:proc:0.1.0"}}, 2_000}} =
               ObserverViews.resolve("observer:observer:-:pubsub:ObsFactor.PubSub:observer:observer:-:proc:0.1.0")

      assert {:error, "pubsub:<server>:<topic> needs a server name" <> _} = ObserverViews.resolve("observer:observer:-:pubsub:Bad Name:x")
      assert {:error, "pubsub:<server>:<topic> needs" <> _} = ObserverViews.resolve("observer:observer:-:pubsub:A.PubSub:" <> String.duplicate("x", 121))
    end

    test "the observer's own VM, in-process: its topics, and one topic's subscribers" do
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, "topics-test")
      {:ok, {_, arg, _}} = ObserverViews.resolve("observer:observer:-:pubsub")
      assert {:ok, body} = ObserverViews.fetch(arg)
      own = Enum.find(body["servers"], &(&1["name"] == "ObsFactor.PubSub"))
      assert %{"topic" => "topics-test", "pattern" => "topics-test", "subscriptions" => 1} in own["topics_list"]

      {:ok, {_, arg, _}} = ObserverViews.resolve("observer:observer:-:pubsub:ObsFactor.PubSub:topics-test")
      assert {:ok, %{"subscriptions" => 1, "subscribers" => [me]}} = ObserverViews.fetch(arg)
      assert me["pid"] == FactoryReport.Observer.pid_text(self()) and me["kind"] == "process"

      {:ok, {_, arg, _}} = ObserverViews.resolve("observer:observer:-:pubsub:Nope.PubSub:x")
      assert {:error, "observer /observer/pubsub answered 404: no PubSub server \"Nope.PubSub\" in this VM" <> _} = ObserverViews.fetch(arg)
    end
  end
end
