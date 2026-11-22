defmodule FactoryReportTest do
  # Not async: the reporter is one per VM (named tables, global telemetry).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest, only: [socket: 1, subscribe_and_join: 3, push: 3]
  require Phoenix.ChannelTest

  alias FactoryReport.{Handlers, Runtime, Tracker}

  @endpoint FactoryReport.TestEndpoint
  @units :factory_report_units

  defp start(opts \\ []) do
    start_supervised!({FactoryReport, Keyword.merge([app: :factory_report, port: false], opts)})
  end

  defp stream(report, kind, name) do
    Enum.find(report["streams"], &(&1["kind"] == kind and &1["name"] == name and not is_map_key(&1, "by")))
  end

  # No log event reaches any handler: for the tests that count rows.
  defp quiet do
    Logger.configure(level: :none)
    on_exit(fn -> Logger.configure(level: :debug) end)
  end

  defp unit(report, kind, name) do
    Enum.find(report["units"], &(&1["kind"] == kind and &1["name"] == name))
  end

  # Kills a process and returns once it is dead and the tracker has dropped
  # it. No sleeping: every round is a call the tracker answers in order.
  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    await_untracked(pid, 10_000)
  end

  defp await_untracked(pid, rounds) do
    Tracker.sync()

    cond do
      not Tracker.tracked?(pid) -> :ok
      rounds == 0 -> flunk("#{inspect(pid)} is still tracked")
      true -> await_untracked(pid, rounds - 1)
    end
  end

  # A process that does nothing, tracked as if a telemetry handler had put it.
  defp fake(kind, name, label) do
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    :ets.insert(@units, {pid, kind, name, nil, label, System.system_time(:second), 0})
    GenServer.cast(Tracker, {:watch, pid})
    pid
  end

  defp request(port, headers \\ "") do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(sock, "GET /report HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n#{headers}\r\n")

    response = read(sock, "")
    :gen_tcp.close(sock)
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")
    {String.to_integer(status), Enum.map(header_lines, &String.downcase/1), body}
  end

  defp read(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> read(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end

  describe "the report" do
    test "has the contract's top-level shape and encodes as JSON" do
      start()
      FactoryReport.event("gif.rendered", duration_us: 1500)
      {:ok, _view, _} = live(build_conn(), "/room/1")

      report = FactoryReport.report()

      assert report["factory_report"] == 1
      assert report["app"] == "factory_report"
      assert {:ok, at, 0} = DateTime.from_iso8601(report["at"])
      assert DateTime.diff(DateTime.utc_now(), at) in 0..5
      assert report["truncated"] == %{"units" => 0, "members" => 0, "streams" => 0}

      assert Enum.sort(Map.keys(report)) ==
               ~w(app at cluster events factory_report runtime streams truncated units)

      decoded = report |> Jason.encode!() |> Jason.decode!()
      assert decoded == report
    end

    test "raises when the reporter is not running" do
      assert_raise ArgumentError, ~r/not running/, fn -> FactoryReport.report() end
      assert FactoryReport.event("nobody.home", duration: 5, error: true) == :ok
    end

    test "start_link refuses to start without an app" do
      assert_raise ArgumentError, ~r/app:/, fn -> FactoryReport.start_link(port: false) end
    end
  end

  describe "cluster" do
    test "a node that is not distributed says so and lists nobody" do
      start()

      if Node.alive?() do
        :ok
      else
        assert %{"node" => "nonode@nohost", "distributed" => false, "connections" => [], "globals" => []} =
                 FactoryReport.report()["cluster"]
      end
    end

    # A real second node: :peer starts one, connects it, and the section
    # must list the connection with byte counts and a global name it holds.
    @tag :distributed
    test "a connected node is listed with its traffic, and globals say where they live" do
      start()

      unless Node.alive?() do
        {:ok, _} = Node.start(:"factory_report_test@127.0.0.1", :longnames)
      end

      {:ok, peer, other} = :peer.start_link(%{name: :peer.random_name(), host: ~c"127.0.0.1", longnames: true})
      on_exit(fn -> catch_exit(:peer.stop(peer)) end)
      true = Node.connect(other)
      :yes = :erpc.call(other, :global, :register_name, [:fr_test_global, :erpc.call(other, :erlang, :whereis, [:init])])
      :global.sync()

      cluster = FactoryReport.report()["cluster"]
      assert cluster["distributed"]
      assert %{"kind" => "visible", "in_bytes" => i, "out_bytes" => o, "send_queue_bytes" => q} =
               Enum.find(cluster["connections"], &(&1["node"] == to_string(other)))

      assert i > 0 and o > 0 and q >= 0
      assert %{"node" => node} = Enum.find(cluster["globals"], &(&1["name"] == ":fr_test_global"))
      assert node == to_string(other)
    end
  end

  describe "runtime" do
    test "kind, versions, uptime, gauges and counters" do
      start()
      runtime = FactoryReport.report()["runtime"]

      assert runtime["kind"] == "beam"
      assert is_integer(runtime["uptime_s"]) and runtime["uptime_s"] >= 0

      versions = runtime["versions"]
      assert versions["otp"] == List.to_string(:erlang.system_info(:otp_release))
      assert versions["elixir"] == System.version()
      assert versions["phoenix"] == to_string(Application.spec(:phoenix, :vsn))
      assert versions["phoenix_live_view"] == to_string(Application.spec(:phoenix_live_view, :vsn))
      assert versions["app"] == "0.1.0"

      gauges = runtime["gauges"]

      for key <- ~w(memory.total memory.processes memory.binary memory.ets memory.atom
                    memory.code process.count process.limit port.count atom.count atom.limit
                    ets.count run_queue schedulers.online) do
        assert is_integer(gauges[key]) and gauges[key] >= 0, "gauge #{key}: #{inspect(gauges[key])}"
      end

      assert gauges["process.count"] < gauges["process.limit"]

      counters = runtime["counters"]

      for key <- ~w(reductions gc.count gc.words_reclaimed io.in_bytes io.out_bytes
                    context_switches) do
        assert is_integer(counters[key]) and counters[key] >= 0, "counter #{key}"
      end

      assert counters["report.handler_errors"] == 0
    end

    test "an app that is not loaded has no version" do
      start(app: :no_such_app)
      refute Map.has_key?(FactoryReport.report()["runtime"]["versions"], "app")
    end

    test "scheduler.utilization is absent until two samples exist, then 0..1" do
      start()
      refute Map.has_key?(FactoryReport.report()["runtime"]["gauges"], "scheduler.utilization")

      # Burn some scheduler time so the second sample differs from the first.
      Enum.reduce(1..200_000, 0, &(&1 + &2))
      value = FactoryReport.report()["runtime"]["gauges"]["scheduler.utilization"]
      assert is_float(value) and value >= 0.0 and value <= 1.0
    end

    test "utilization is the busy share between two samples" do
      assert Runtime.utilization({100, 1_000}, {350, 2_000}) == 0.25
      assert Runtime.utilization({100, 1_000}, {100, 1_000}) == nil
      assert Runtime.utilization(nil, {100, 1_000}) == nil
    end

    test "counters only grow between two reports" do
      start()
      first = FactoryReport.report()["runtime"]["counters"]
      second = FactoryReport.report()["runtime"]["counters"]
      for {key, value} <- first, do: assert(second[key] >= value, key)
      assert second["reductions"] > first["reductions"]
    end
  end

  describe "liveviews" do
    test "a connected LiveView is a unit with its route and path; it goes when the process exits" do
      start()
      Process.flag(:trap_exit, true)

      {:ok, view, _html} = live(build_conn(), "/room/42?secret=hunter2")
      report = FactoryReport.report()

      assert [unit] = report["units"]
      assert unit["kind"] == "liveview"
      assert unit["name"] == "FactoryReport.TestLive.Room"
      assert unit["route"] == "/room/:id"
      assert unit["count"] == 1
      assert [member] = unit["members"]
      assert member["label"] == "/room/42"
      assert member["id"] =~ ~r/^[0-9a-f]{8}$/
      assert {:ok, since, 0} = DateTime.from_iso8601(member["since"])
      assert DateTime.diff(DateTime.utc_now(), since) in 0..5
      assert member["counters"] == %{"events" => 0}
      assert member["gauges"]["memory"] > 0
      assert member["gauges"]["message_queue"] == 0
      assert unit["gauges"] == member["gauges"]

      # Privacy: the query string and the param value are nowhere but the label's path.
      refute Jason.encode!(report) =~ "hunter2"
      refute Jason.encode!(report) =~ "secret"

      # The disconnected render and the connected mount are both mounts.
      assert %{"count" => 2, "errors" => 0} = stream(report, "liveview.mount", "FactoryReport.TestLive.Room")
      assert %{"count" => 2} = stream(report, "liveview.params", "FactoryReport.TestLive.Room")
      assert %{"count" => 1, "errors" => 0} = stream(report, "http.route", "GET /room/:id")

      kill(view.pid)
      assert FactoryReport.report()["units"] == []
      assert :ets.info(@units, :size) == 0
    end

    test "events count into the stream and into the member; the id is stable" do
      start()
      {:ok, view, _html} = live(build_conn(), "/room/7")
      [%{"members" => [before]}] = FactoryReport.report()["units"]

      render_click(view, "ping")
      render_click(view, "ping")
      render_click(view, "ping")

      report = FactoryReport.report()
      assert [%{"members" => [member]}] = report["units"]
      assert member["counters"] == %{"events" => 3}
      assert member["id"] == before["id"]
      assert member["since"] == before["since"]

      assert %{"count" => 3, "errors" => 0, "duration_us" => us} =
               stream(report, "liveview.event", "FactoryReport.TestLive.Room#ping")

      assert is_integer(us) and us >= 0
    end

    test "a patch moves the member to its new path" do
      start()
      {:ok, view, _html} = live(build_conn(), "/room/1")
      render_patch(view, "/room/2?x=1")

      assert [%{"route" => "/room/:id", "count" => 1, "members" => [%{"label" => "/room/2"}]}] =
               FactoryReport.report()["units"]
    end

    test "sessions of one view are one unit; a nested LiveView is where its root is" do
      start()
      {:ok, _a, _} = live(build_conn(), "/counter")
      {:ok, _b, _} = live(build_conn(), "/counter")
      report = FactoryReport.report()

      counter = unit(report, "liveview", "FactoryReport.TestLive.Counter")
      assert counter["count"] == 2
      assert counter["route"] == "/counter"
      assert length(counter["members"]) == 2

      assert counter["gauges"]["memory"] ==
               counter["members"] |> Enum.map(& &1["gauges"]["memory"]) |> Enum.sum()

      memories = Enum.map(counter["members"], & &1["gauges"]["memory"])
      assert memories == Enum.sort(memories, :desc)
      assert length(Enum.uniq_by(counter["members"], & &1["id"])) == 2

      child = unit(report, "liveview", "FactoryReport.TestLive.Child")
      assert child["count"] == 2
      assert child["route"] == "/counter"
      assert Enum.all?(child["members"], &(&1["label"] == "/counter"))
    end

    test "a LiveView with no mount/3 and no handle_params/3 is still tracked, by its renders" do
      start()
      {:ok, _view, _} = live(build_conn(), "/bare")

      assert [%{"name" => "FactoryReport.TestLive.Bare", "count" => 1, "route" => nil, "members" => [member]}] =
               FactoryReport.report()["units"]

      # Nothing told us its path: the label falls back to the view's name.
      assert member["label"] == "FactoryReport.TestLive.Bare"
    end

    test "an event that raises is an error, and a name seen only failing gets no row of its own" do
      start()
      Process.flag(:trap_exit, true)

      {:ok, view, _} = live(build_conn(), "/counter")
      render_click(view, "inc")
      ref = Process.monitor(view.pid)
      catch_exit(render_click(view, "crash"))
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

      report = FactoryReport.report()

      assert %{"count" => 1, "errors" => 0} =
               stream(report, "liveview.event", "FactoryReport.TestLive.Counter#inc")

      assert stream(report, "liveview.event", "FactoryReport.TestLive.Counter#crash") == nil
      assert %{"count" => 1, "errors" => 1} = stream(report, "liveview.event", "(other)")
    end

    test "the tracker picks its processes up again after a restart" do
      start()
      Process.flag(:trap_exit, true)
      {:ok, view, _} = live(build_conn(), "/room/9")

      tracker = Process.whereis(Tracker)
      ref = Process.monitor(tracker)
      Process.exit(tracker, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      await_restart(tracker, 10_000)

      assert [%{"count" => 1}] = FactoryReport.report()["units"]
      render_click(view, "ping")

      assert %{"count" => 1} =
               stream(FactoryReport.report(), "liveview.event", "FactoryReport.TestLive.Room#ping")

      kill(view.pid)
      assert FactoryReport.report()["units"] == []
    end
  end

  # The supervisor restarts the tracker; ask it until the new one is there.
  defp await_restart(old, rounds) do
    Supervisor.count_children(FactoryReport)

    case Process.whereis(Tracker) do
      pid when is_pid(pid) and pid != old -> Tracker.sync()
      _ when rounds == 0 -> flunk("the tracker did not come back")
      _ -> await_restart(old, rounds - 1)
    end
  end

  describe "http routes" do
    test "a controller request counts under its method and route pattern" do
      start()
      assert text_response(get(build_conn(), "/hello/world?token=abc"), 200) == "hello world"
      assert text_response(get(build_conn(), "/hello/again"), 200) == "hello again"

      report = FactoryReport.report()

      assert %{"count" => 2, "errors" => 0, "duration_us" => us} =
               stream(report, "http.route", "GET /hello/:name")

      assert us >= 0
      refute Jason.encode!(report) =~ "world"
      refute Jason.encode!(report) =~ "abc"
    end

    test "a 5xx answer and a raise are errors" do
      start()
      assert response(get(build_conn(), "/broken"), 500)
      assert_raise RuntimeError, "boom", fn -> get(build_conn(), "/boom") end

      report = FactoryReport.report()
      assert %{"count" => 1, "errors" => 1} = stream(report, "http.route", "GET /broken")
      assert %{"count" => 1, "errors" => 1} = stream(report, "http.route", "GET /boom")
    end
  end

  describe "channels" do
    test "a joined channel is a unit named by its topic prefix; its events are a stream" do
      start()
      Process.flag(:trap_exit, true)

      {:ok, _, joined} =
        subscribe_and_join(socket(FactoryReport.TestSocket), FactoryReport.TestChannel, "room:user-1234")

      assert {:error, _} =
               subscribe_and_join(socket(FactoryReport.TestSocket), FactoryReport.TestChannel, "room:locked")

      ref = push(joined, "say", %{"text" => "private words"})
      Phoenix.ChannelTest.assert_reply(ref, :ok)

      report = FactoryReport.report()

      assert [%{"kind" => "channel", "name" => "room:*", "route" => nil, "count" => 1, "members" => [member]}] =
               report["units"]

      assert member["label"] == "room:*"
      assert member["counters"] == %{"events" => 1}
      assert %{"count" => 2, "errors" => 1} = stream(report, "channel.join", "FactoryReport.TestChannel")
      assert %{"count" => 1, "errors" => 0} = stream(report, "channel.event", "FactoryReport.TestChannel#say")
      refute Jason.encode!(report) =~ "user-1234"
      refute Jason.encode!(report) =~ "private words"

      kill(joined.channel_pid)
      assert FactoryReport.report()["units"] == []
    end
  end

  describe "custom events" do
    test "count, errors and both ways of giving a duration" do
      start()
      FactoryReport.event("gif.rendered")
      FactoryReport.event("gif.rendered", duration_us: 1_500)

      FactoryReport.event("gif.rendered",
        duration: System.convert_time_unit(2, :millisecond, :native),
        error: true
      )

      FactoryReport.event(:atom_name, duration_us: 7)

      report = FactoryReport.report()

      assert stream(report, "custom", "gif.rendered") ==
               %{
                 "kind" => "custom",
                 "name" => "gif.rendered",
                 "count" => 3,
                 "errors" => 1,
                 "duration_us" => 3_500
               }

      assert %{"count" => 1, "duration_us" => 7} = stream(report, "custom", "atom_name")
    end

    test "nonsense arguments do not raise" do
      start()
      assert FactoryReport.event("x", duration: :soon) == :ok
      assert FactoryReport.event("x", duration_us: -5) == :ok
      assert FactoryReport.event(%{not: "a name"}, :not_a_list) == :ok
      assert %{"count" => 2, "duration_us" => 0} = stream(FactoryReport.report(), "custom", "x")
    end
  end

  describe "ecto and finch events (synthetic: the shapes those libraries emit)" do
    defmodule Repo do
      def config, do: [telemetry_prefix: [:my_app, :repo]]
    end

    defmodule PlainRepo do
    end

    test "queries of a configured repo count under the repo's name" do
      start(repos: [Repo, PlainRepo])
      ms = System.convert_time_unit(1, :millisecond, :native)

      :telemetry.execute([:my_app, :repo, :query], %{total_time: 3 * ms, query_time: ms}, %{
        repo: Repo,
        result: {:ok, %{}},
        query: "SELECT secret"
      })

      :telemetry.execute([:my_app, :repo, :query], %{total_time: ms}, %{repo: Repo, result: {:error, %{}}})
      :telemetry.execute(Handlers.repo_event(PlainRepo), %{total_time: ms}, %{result: {:ok, %{}}})

      report = FactoryReport.report()

      assert stream(report, "db.query", "FactoryReportTest.Repo") ==
               %{
                 "kind" => "db.query",
                 "name" => "FactoryReportTest.Repo",
                 "count" => 2,
                 "errors" => 1,
                 "duration_us" => 4_000
               }

      assert %{"count" => 1} = stream(report, "db.query", "FactoryReportTest.PlainRepo")
      assert Handlers.repo_event(PlainRepo) == [:factory_report_test, :plain_repo, :query]
      refute Jason.encode!(report) =~ "SELECT"
    end

    test "finch requests count under the host" do
      start()
      ms = System.convert_time_unit(1, :millisecond, :native)

      request = %{
        scheme: :https,
        host: "api.example.com",
        port: 443,
        method: "GET",
        path: "/v1/secret",
        query: "key=abc"
      }

      :telemetry.execute([:finch, :request, :stop], %{duration: 10 * ms}, %{
        name: MyFinch,
        request: request,
        result: {:ok, %{status: 200}}
      })

      :telemetry.execute([:finch, :request, :stop], %{duration: ms}, %{
        name: MyFinch,
        request: request,
        result: {:ok, %{status: 503}}
      })

      :telemetry.execute([:finch, :request, :stop], %{duration: ms}, %{
        name: MyFinch,
        request: request,
        result: {:error, :timeout}
      })

      :telemetry.execute([:finch, :request, :exception], %{duration: ms}, %{
        name: MyFinch,
        request: request,
        kind: :exit,
        reason: :x,
        stacktrace: []
      })

      report = FactoryReport.report()

      assert stream(report, "outbound.http", "api.example.com") ==
               %{
                 "kind" => "outbound.http",
                 "name" => "api.example.com",
                 "count" => 4,
                 "errors" => 3,
                 "duration_us" => 13_000
               }

      refute Jason.encode!(report) =~ "secret"
    end
  end

  describe "bounds" do
    test "at most 300 streams, the busiest first, the rest counted" do
      quiet()
      start()

      for i <- 1..350, _ <- 1..i, do: FactoryReport.event("e#{i}")

      report = FactoryReport.report()
      assert length(report["streams"]) == 300
      assert report["truncated"]["streams"] == 50
      assert hd(report["streams"])["name"] == "e350"
      assert List.last(report["streams"])["name"] == "e51"
      counts = Enum.map(report["streams"], & &1["count"])
      assert counts == Enum.sort(counts, :desc)
    end

    test "a kind holds a bounded number of names; later ones are counted as (other)" do
      quiet()
      start(max_stream_names: 10)

      for i <- 1..25, do: FactoryReport.event("name#{i}")
      FactoryReport.event("name1")
      FactoryReport.event("name25", error: true)

      report = FactoryReport.report()
      custom = Enum.filter(report["streams"], &(&1["kind"] == "custom"))
      assert length(custom) == 11
      assert %{"count" => 2} = stream(report, "custom", "name1")
      assert %{"count" => 16, "errors" => 1} = stream(report, "custom", "(other)")
      assert :ets.info(:factory_report_streams, :size) <= 12
    end

    test "names are cut at 120 characters and are always valid text" do
      start()
      FactoryReport.event(String.duplicate("n", 500))
      FactoryReport.event(String.duplicate("é", 100))
      FactoryReport.event(<<255, 254, "ok">>)

      names = for %{"name" => name} <- FactoryReport.report()["streams"], do: name
      assert String.duplicate("n", 120) in names
      assert String.duplicate("é", 60) in names
      assert "??ok" in names
      assert Enum.all?(names, &(String.valid?(&1) and String.length(&1) <= 120))
    end

    test "at most 100 units and 20 members each, the largest first, the rest counted" do
      start()

      big = for _ <- 1..30, do: fake("liveview", "Big", "/big")
      small = for i <- 1..120, do: fake("liveview", "Small#{i}", "/small")
      report = FactoryReport.report()

      assert length(report["units"]) == 100
      assert report["truncated"]["units"] == 21
      assert report["truncated"]["members"] == 10

      assert %{"name" => "Big", "count" => 30, "members" => members, "gauges" => gauges} = hd(report["units"])
      assert length(members) == 20
      assert gauges["memory"] > members |> Enum.map(& &1["gauges"]["memory"]) |> Enum.sum()

      Enum.each(big ++ small, &kill/1)
      assert FactoryReport.report()["units"] == []
    end

    test "a tracked process that is already dead is not reported" do
      start()
      pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
      :ets.insert(@units, {pid, "liveview", "Ghost", nil, "/ghost", System.system_time(:second), 0})
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      # Its row is still in the table (nobody told the tracker to watch it).
      assert Tracker.tracked?(pid)
      assert FactoryReport.report()["units"] == []
    end
  end

  describe "the plug" do
    defp call(conn, opts \\ []), do: FactoryReport.Plug.call(conn, FactoryReport.Plug.init(opts))

    test "GET /report and GET / answer the report; everything else is 404" do
      start()

      for path <- ["/report", "/"] do
        conn = call(Plug.Test.conn(:get, path))
        assert conn.status == 200
        assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]
        assert %{"factory_report" => 1, "app" => "factory_report"} = Jason.decode!(conn.resp_body)
      end

      assert call(Plug.Test.conn(:get, "/metrics")).status == 404
      assert call(Plug.Test.conn(:get, "/report/more")).status == 404
      assert call(Plug.Test.conn(:post, "/report")).status == 404
    end

    test "with a token: 401 without it or with a wrong one, 200 with it" do
      start(token: "s3cret")

      assert call(Plug.Test.conn(:get, "/report")).status == 401

      wrong = Plug.Test.conn(:get, "/report") |> Plug.Conn.put_req_header("authorization", "Bearer nope")
      assert call(wrong).status == 401

      basic = Plug.Test.conn(:get, "/report") |> Plug.Conn.put_req_header("authorization", "s3cret")
      assert call(basic).status == 401

      right = Plug.Test.conn(:get, "/report") |> Plug.Conn.put_req_header("authorization", "Bearer s3cret")
      assert call(right).status == 200

      # Still 404, not 401, for what does not exist.
      assert call(Plug.Test.conn(:get, "/other")).status == 404
    end

    test "an empty token is no token; the plug's own token overrides" do
      start(token: "")
      assert call(Plug.Test.conn(:get, "/report")).status == 200
      assert call(Plug.Test.conn(:get, "/report"), token: "mine").status == 401
    end

    test "503 when the reporter is not running" do
      assert call(Plug.Test.conn(:get, "/report")).status == 503
    end
  end

  describe "the listener" do
    test "answers a real HTTP request on its own port" do
      start(port: 0, ip: {127, 0, 0, 1})
      port = FactoryReport.port()
      assert is_integer(port) and port > 0

      {:ok, _view, _} = live(build_conn(), "/room/5")
      FactoryReport.event("over.the.wire")

      assert {200, headers, body} = request(port)
      assert "content-type: application/json" in headers
      report = Jason.decode!(body)
      assert report["factory_report"] == 1
      assert [%{"kind" => "liveview", "route" => "/room/:id"}] = report["units"]
      assert Enum.any?(report["streams"], &(&1["name"] == "over.the.wire"))
    end

    test "with a token: 401 without, 200 with" do
      start(port: 0, ip: {127, 0, 0, 1}, token: "s3cret")
      port = FactoryReport.port()

      assert {401, _, _} = request(port)
      assert {401, _, _} = request(port, "authorization: Bearer wrong\r\n")
      assert {200, _, body} = request(port, "authorization: Bearer s3cret\r\n")
      assert %{"factory_report" => 1} = Jason.decode!(body)
    end

    test "port: false starts no listener" do
      start()
      assert FactoryReport.port() == nil
    end
  end

  describe "handlers" do
    test "garbage measurements and metadata never raise and never detach a handler" do
      start()

      attached = fn ->
        ids = for %{id: {FactoryReport, _} = id} <- :telemetry.list_handlers([]), uniq: true, do: id
        length(ids)
      end

      before = attached.()
      assert before == 4

      events = Handlers.events() |> Map.values() |> Enum.concat()
      assert length(events) == 17

      garbage = [
        {%{}, %{}},
        {%{duration: "soon"}, %{socket: nil, conn: nil, request: nil, event: nil}},
        {%{duration: -1}, %{socket: %{view: "not a module", transport_pid: self()}, event: 12, uri: 7}},
        {%{duration: 1},
         %{
           socket: %{view: Some.View, transport_pid: self(), router: Not.A.Router},
           event: <<255>>,
           uri: "http://[bad"
         }},
        {%{duration: 1}, %{conn: %{method: :get, status: "ok"}, route: nil, result: :weird, component: 5}},
        {:not_a_map, :not_a_map},
        {nil, [1, 2, 3]}
      ]

      for event <- events, {measurements, metadata} <- garbage do
        assert Handlers.handle(event, measurements, metadata, nil) == :ok

        # :telemetry itself only takes maps.
        if is_map(measurements) and is_map(metadata) do
          assert :telemetry.execute(event, measurements, metadata) == :ok
        end
      end

      assert Handlers.handle([:unknown, :event], %{}, %{}, nil) == :ok
      assert attached.() == before

      # What was swallowed is counted, and the report still works.
      report = FactoryReport.report()
      assert report["runtime"]["counters"]["report.handler_errors"] > 0
      assert Jason.encode!(report)

      # The garbage with a pid-carrying socket tracked this test process; it
      # is alive, so it shows; no name is longer than the bound.
      for unit <- report["units"], do: assert(String.length(unit["name"]) <= 120)
    end

    test "they are detached when the reporter stops" do
      start()
      stop_supervised!(FactoryReport)
      assert Enum.filter(:telemetry.list_handlers([]), &match?({FactoryReport, _}, &1.id)) == []
      assert :ets.whereis(:factory_report_streams) == :undefined
    end
  end
end
