defmodule FactoryReport.PubSubTest do
  # Not async: the reporter is one per VM, and the walk sees every server.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest, only: [socket: 1, subscribe_and_join: 3]
  import Plug.Test
  require Phoenix.ChannelTest

  alias FactoryReport.Observer

  @endpoint FactoryReport.TestEndpoint

  defp start(opts \\ []) do
    start_supervised!({FactoryReport, Keyword.merge([app: :factory_report, port: false, observer: true], opts)})
  end

  # A real Phoenix.PubSub, as an app starts one.
  defp pubsub(name, opts \\ []) do
    start_supervised!(%{
      id: name,
      type: :supervisor,
      start: {Supervisor, :start_link, [[{Phoenix.PubSub, [name: name] ++ opts}], [strategy: :one_for_one]]}
    })

    name
  end

  # A process subscribed to `topics`, alive until the test ends.
  defp subscriber(ps, topics) do
    me = self()

    pid =
      spawn_link(fn ->
        Enum.each(topics, &Phoenix.PubSub.subscribe(ps, &1))
        send(me, :subscribed)
        receive(do: (:stop -> :ok))
      end)

    assert_receive :subscribed
    pid
  end

  defp server(report_or_list, name) do
    list = if is_map(report_or_list), do: report_or_list["pubsub"], else: report_or_list
    Enum.find(list, &(&1["name"] == name))
  end

  defp get_json(path) do
    conn = FactoryReport.Plug.call(conn(:get, path), [])
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  describe "finding servers" do
    test "a Phoenix.PubSub is its Registry: name, adapter, keys and partitions, read off a running one" do
      ps = pubsub(PSTest.Found, registry_size: 3)

      # What Phoenix.PubSub 2.x starts, as the module doc says.
      assert is_pid(Process.whereis(PSTest.Found.Supervisor))
      assert is_pid(Process.whereis(PSTest.Found.Adapter))
      assert {:ok, {Phoenix.PubSub.PG2, PSTest.Found.Adapter, Phoenix.PubSub}} = Registry.meta(ps, :pubsub)

      found = FactoryReport.PubSub.server(ps)
      assert found.text == "PSTest.Found"
      assert found.adapter == "Phoenix.PubSub.PG2"
      assert found.keys == "duplicate"
      assert found.partitions == 3

      # Not a PubSub: a plain registry, a plain process, an unnamed table.
      start_supervised!({Registry, keys: :duplicate, name: PSTest.PlainRegistry})
      assert FactoryReport.PubSub.server(PSTest.PlainRegistry) == nil
      assert FactoryReport.PubSub.server(:code_server) == nil

      names = Enum.map(FactoryReport.PubSub.servers(), & &1.text)
      assert "PSTest.Found" in names and "FactoryReport.TestPubSub" in names
      refute "PSTest.PlainRegistry" in names
    end

    test "the default partitions: ceil(schedulers / 4)" do
      pubsub(PSTest.Default)
      assert FactoryReport.PubSub.server(PSTest.Default).partitions == ceil(System.schedulers_online() / 4)
    end

    # group_by: :key asks the Registry for keys {:duplicate, :key}, which
    # Elixir 1.18 refuses ("expected :keys to be given and be one of :unique
    # or :duplicate"): such a server only exists on a newer Elixir.
    if Version.match?(System.version(), ">= 1.19.0") do
      test "group_by: :key" do
        pubsub(PSTest.ByKey, group_by: :key)
        assert FactoryReport.PubSub.server(PSTest.ByKey).keys == "duplicate_by_key"
      end
    end
  end

  describe "the report's pubsub section" do
    test "per server: topics, subscriptions, distinct subscribers, the top patterns by subscriptions" do
      start()
      ps = pubsub(PSTest.Report)
      a = subscriber(ps, ["room:1", "room:2", "lobby"])
      _b = subscriber(ps, ["room:1", "lobby"])
      _c = subscriber(ps, ["room:1"])
      # The same process twice on one topic is two subscriptions.
      send(a, :noop)
      Phoenix.PubSub.subscribe(ps, "room:1")
      Phoenix.PubSub.subscribe(ps, "room:1")

      report = FactoryReport.report()
      s = server(report, "PSTest.Report")

      assert s == %{
               "name" => "PSTest.Report",
               "adapter" => "Phoenix.PubSub.PG2",
               "keys" => "duplicate",
               "partitions" => ceil(System.schedulers_online() / 4),
               "topics" => 3,
               "subscriptions" => 8,
               "subscribers" => 4,
               # room:1 and room:2 are one pattern: the report names no topic
               "top" => [
                 %{"pattern" => "room:#", "topics" => 2, "subscriptions" => 6},
                 %{"pattern" => "lobby", "topics" => 1, "subscriptions" => 2}
               ],
               "patterns_cut" => 0,
               "counts_only" => nil,
               "walk_limit" => 100_000,
               "took_ms" => s["took_ms"]
             }

      assert is_float(s["took_ms"])
      assert report["truncated"]["pubsub"] == 0
      assert report |> Jason.encode!() |> Jason.decode!() == report
    end

    test "the top 25 patterns and how many were cut; any term is a topic, written safely" do
      start()
      ps = pubsub(PSTest.Many)
      subscriber(ps, for(w <- ~w(a b c d e f g h i j k l m n o p q r s t u v w x y z ab ac ad ae ag ah ai aj ak al am an ao ap), do: "t:" <> w))
      subscriber(ps, ["t:g", "room:1", "room:2", "room:3"])

      # Phoenix.PubSub.subscribe/3 takes binaries only, but the registry
      # takes anything: a tuple, and bytes that are not UTF-8.
      {:ok, _} = Registry.register(ps, {:user, 42}, nil)
      {:ok, _} = Registry.register(ps, <<255, 0, ?a>>, nil)
      {:ok, _} = Registry.register(ps, String.duplicate("x", 500), nil)

      s = server(FactoryReport.report(), "PSTest.Many")
      assert s["topics"] == 46
      assert length(s["top"]) == 25
      # 40 t: patterns, room:#, three odd ones = 44 patterns, 25 shown
      assert s["patterns_cut"] == 19
      assert Enum.take(s["top"], 2) == [
               %{"pattern" => "room:#", "topics" => 3, "subscriptions" => 3},
               %{"pattern" => "t:g", "topics" => 1, "subscriptions" => 2}
             ]

      refute Jason.encode!(s) =~ "user, 42"

      texts = FactoryReport.PubSub.read(%{"server" => "PSTest.Many", "limit" => "1000"})["servers"] |> hd() |> Map.fetch!("topics_list") |> Enum.map(& &1["topic"])
      assert "{:user, 42}" in texts
      assert ~s(<<255, 0, 97>>) in texts
      assert String.duplicate("x", 120) in texts
      assert Enum.all?(texts, &(String.valid?(&1) and byte_size(&1) <= 120))
    end

    test "past the walk limit, subscriptions are counted and topics are not walked; it says so" do
      start()
      ps = pubsub(PSTest.Huge, registry_size: 1)
      limit = FactoryReport.PubSub.walk_limit()

      # Just under the limit first: the walk this costs every 5 s at worst.
      holder =
        spawn_link(fn ->
          for i <- 1..limit, do: {:ok, _} = Registry.register(ps, "topic:#{rem(i, 5000)}", nil)
          receive(do: (:more -> {:ok, _} = Registry.register(ps, "one-more", nil)))
          receive(do: (:stop -> :ok))
        end)

      wait_count(ps, limit)
      s = server(FactoryReport.report(), "PSTest.Huge")
      assert s["subscriptions"] == limit and s["topics"] == 5000 and s["counts_only"] == nil
      assert s["top"] == [%{"pattern" => "topic:#", "topics" => 5000, "subscriptions" => limit}]
      IO.puts("\n  walk of #{limit} subscriptions, 5000 topics: #{s["took_ms"]} ms")

      send(holder, :more)
      wait_count(ps, limit + 1)
      s = server(FactoryReport.report(), "PSTest.Huge")
      assert s["subscriptions"] == limit + 1
      assert s["topics"] == nil and s["subscribers"] == nil and s["top"] == []
      assert s["counts_only"] =~ "more than the walk limit of 100000"
      IO.puts("  over the limit, counts only: #{s["took_ms"]} ms")
    end
  end

  defp wait_count(ps, n, tries \\ 500) do
    cond do
      Registry.count(ps) == n -> :ok
      tries == 0 -> flunk("registry never reached #{n}")
      true -> Process.sleep(10) && wait_count(ps, n, tries - 1)
    end
  end

  describe "GET /observer/pubsub" do
    test "every server and all its topics, limited and sorted" do
      start()
      ps = pubsub(PSTest.View)
      subscriber(ps, ["b", "a", "c"])
      subscriber(ps, ["c"])

      {200, body} = get_json("/observer/pubsub?limit=2")
      assert body["limit"] == 2 and body["sort"] == "subscriptions"
      s = server(body["servers"], "PSTest.View")
      assert s["topics_list"] == [
               %{"topic" => "c", "pattern" => "c", "subscriptions" => 2},
               %{"topic" => "a", "pattern" => "a", "subscriptions" => 1}
             ]

      assert s["topics_cut"] == 1
      assert s["topics"] == 3 and s["subscriptions"] == 4
      assert is_binary(body["node"]) and is_float(body["took_ms"])

      {200, body} = get_json("/observer/pubsub?server=PSTest.View&sort=topic")
      assert [%{"topics_list" => list}] = body["servers"]
      assert Enum.map(list, & &1["topic"]) == ["a", "b", "c"]

      assert {404, %{"error" => "no PubSub server \"Nope\" in this VM" <> _}} = get_json("/observer/pubsub?server=Nope")
      assert {400, %{"error" => "topic= needs server= too" <> _}} = get_json("/observer/pubsub?topic=a")
      assert {400, %{"error" => "sort must be one of subscriptions, topic"}} = get_json("/observer/pubsub?sort=age")
      assert {400, %{"error" => "limit must be an integer from 1 to 1000"}} = get_json("/observer/pubsub?limit=0")
      assert "pubsub" in elem(get_json("/observer"), 1)["reads"]
    end

    test "one topic's subscribers: a LiveView, a channel and a plain process, told apart" do
      start()
      Process.flag(:trap_exit, true)
      ps = FactoryReport.TestPubSub

      {:ok, view, _} = live(build_conn(), "/feed/9")
      plain = subscriber(ps, ["feed:9"])

      {200, body} = get_json("/observer/pubsub?server=FactoryReport.TestPubSub&topic=feed:9")
      assert body["server"] == "FactoryReport.TestPubSub"
      assert body["topic"] == "feed:9"
      assert body["subscriptions"] == 2
      assert body["subscribers_cut"] == 0

      lv = Enum.find(body["subscribers"], &(&1["pid"] == Observer.pid_text(view.pid)))
      assert lv["kind"] == "liveview"
      assert lv["module"] == "FactoryReport.TestLive.Feed"
      assert lv["initial_call"] == "FactoryReport.TestLive.Feed.mount/3"
      assert lv["entries"] == 1 and lv["fastlane"] == false

      for key <- ~w(pid registered_name initial_call current_function message_queue_len memory),
          do: assert(Map.has_key?(lv, key))

      p = Enum.find(body["subscribers"], &(&1["pid"] == Observer.pid_text(plain)))
      assert p["kind"] == "process" and p["module"] == nil

      # A channel subscribes its own process with a fastlane to the transport.
      {:ok, _, ch} = subscribe_and_join(socket(FactoryReport.TestSocket), FactoryReport.TestChannel, "room:9")
      {200, body} = get_json("/observer/pubsub?server=FactoryReport.TestPubSub&topic=room:9")
      c = Enum.find(body["subscribers"], &(&1["pid"] == Observer.pid_text(ch.channel_pid)))
      assert c["kind"] == "channel" and c["module"] == "FactoryReport.TestChannel" and c["fastlane"] == true

      # A topic nobody is on: 200, nobody.
      {200, body} = get_json("/observer/pubsub?server=FactoryReport.TestPubSub&topic=nobody")
      assert body["subscriptions"] == 0 and body["subscribers"] == []
    end

    test "a topic that is not a string, asked for by its text; the biggest mailbox first" do
      start()
      ps = pubsub(PSTest.Terms)
      {:ok, _} = Registry.register(ps, {:user, 42}, nil)
      send(self(), :one)
      send(self(), :two)
      quiet = spawn_link(fn -> Registry.register(ps, {:user, 42}, nil) && receive(do: (:stop -> :ok)) end)
      Process.sleep(20)

      body = Observer.dispatch("GET", ["pubsub"], %{"server" => "PSTest.Terms", "topic" => "{:user, 42}"}) |> elem(1)
      assert body["subscriptions"] == 2
      assert [first, second] = body["subscribers"]
      assert first["pid"] == Observer.pid_text(self()) and first["message_queue_len"] == 2
      assert second["pid"] == Observer.pid_text(quiet)
    end
  end

  describe "broadcast/3, counted" do
    test "counts the topic's pattern in the pubsub.broadcast stream, then broadcasts" do
      start()
      Phoenix.PubSub.subscribe(FactoryReport.TestPubSub, "room:42")

      assert :ok = FactoryReport.PubSub.broadcast(FactoryReport.TestPubSub, "room:42", :hello)
      assert :ok = FactoryReport.PubSub.broadcast(FactoryReport.TestPubSub, "room:7", :other)
      assert_receive :hello
      refute_receive :other

      row = Enum.find(FactoryReport.report()["streams"], &(&1["kind"] == "pubsub.broadcast"))
      assert row["name"] == "room:#" and row["count"] == 2
    end

    test "pattern/1 blanks ids" do
      assert FactoryReport.PubSub.pattern("room:42") == "room:#"
      assert FactoryReport.PubSub.pattern("user:3f2a9c1e-77b0-4c1e-9d1a-0b6f3b1e2a4c:typing") == "user:#:typing"
      assert FactoryReport.PubSub.pattern("lv:phx-F_xUq1abc") == "lv:phx-#"
      assert FactoryReport.PubSub.pattern("posts") == "posts"
    end
  end
end
