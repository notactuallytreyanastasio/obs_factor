defmodule FactoryReport.SecondRoundTest do
  # Who did it (`by`), what was logged (`log` streams, `events`), and the
  # JSON formatter. Not async: the reporter is one per VM.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  require Logger

  alias FactoryReport.{Attribution, JSONFormatter, LogHandler, Message, Tracker}

  @endpoint FactoryReport.TestEndpoint
  @room %{"kind" => "liveview", "name" => "FactoryReport.TestLive.Room"}
  @route %{"kind" => "http.route", "name" => "GET /work"}

  defp start(opts \\ []) do
    start_supervised!({FactoryReport, Keyword.merge([app: :factory_report, port: false], opts)})
  end

  defp total(report, kind, name) do
    Enum.find(report["streams"], &(&1["kind"] == kind and &1["name"] == name and not is_map_key(&1, "by")))
  end

  defp by(report, kind, name) do
    for %{"by" => by} = row <- report["streams"], row["kind"] == kind, row["name"] == name, into: %{} do
      {by, Map.drop(row, ["by", "kind", "name"])}
    end
  end

  defp quiet do
    Logger.configure(level: :none)
    on_exit(fn -> Logger.configure(level: :debug) end)
  end

  defp event(level, msg, meta \\ %{}) do
    %{level: level, msg: msg, meta: Map.merge(%{time: 1_795_077_602_123_456}, meta)}
  end

  defp decode(line) do
    line = IO.iodata_to_binary(line)
    assert String.ends_with?(line, "\n")
    refute String.contains?(String.trim_trailing(line, "\n"), "\n")
    Jason.decode!(line)
  end

  describe "by" do
    test "work done in a LiveView's process is broken down by that view, and still in the total" do
      start(repos: [FactoryReport.TestRepo])
      {:ok, view, _} = live(build_conn(), "/room/1")
      render_click(view, "work")
      render_click(view, "work")

      # The same things from a process that is nobody's page.
      FactoryReport.TestWork.run("nobody")
      report = FactoryReport.report()

      for {kind, name, us} <- [
            {"db.query", "FactoryReport.TestRepo", 2_000},
            {"outbound.http", "api.example.com", 3_000},
            {"custom", "work", 0},
            {"log", "warning", 0}
          ] do
        assert %{"count" => 3, "errors" => 0, "duration_us" => all} = total(report, kind, name)
        assert all == 3 * us

        assert by(report, kind, name) == %{@room => %{"count" => 2, "errors" => 0, "duration_us" => 2 * us}},
               "#{kind} #{name}"
      end

      # A total row has no "by" key at all.
      refute Map.has_key?(total(report, "custom", "work"), "by")
    end

    test "a task is attributed to its caller, two hops up and no further" do
      start()
      {:ok, view, _} = live(build_conn(), "/room/1")
      render_click(view, "work")
      report = FactoryReport.report()

      assert %{@room => %{"count" => 1}} = by(report, "custom", "task1")
      assert %{@room => %{"count" => 1}} = by(report, "custom", "task2")
      assert %{"count" => 1} = total(report, "custom", "task3")
      assert by(report, "custom", "task3") == %{}
    end

    test "work done while a request is routed is broken down by its route; the mark ends with the request" do
      start(repos: [FactoryReport.TestRepo])
      assert text_response(get(build_conn(), "/work?secret=1"), 200) == "done"

      # Phoenix.ConnTest runs the request in this process: after it, this
      # process is nobody's page again.
      assert Attribution.current() == nil
      FactoryReport.event("work")
      report = FactoryReport.report()

      assert by(report, "db.query", "FactoryReport.TestRepo") == %{
               @route => %{"count" => 1, "errors" => 0, "duration_us" => 2_000}
             }

      assert %{@route => %{"count" => 1}} = by(report, "outbound.http", "api.example.com")
      assert %{@route => %{"count" => 1}} = by(report, "custom", "work")
      assert %{@route => %{"count" => 1}} = by(report, "custom", "task1")
      assert %{@route => %{"count" => 1}} = by(report, "custom", "task2")
      assert by(report, "custom", "task3") == %{}
      assert %{"count" => 2} = total(report, "custom", "work")

      # The warning logged by the controller is the route's too.
      assert %{@route => %{"count" => warnings}} = by(report, "log", "warning")
      assert warnings == 1
      refute Jason.encode!(report) =~ "secret"
    end

    test "the disconnected render is the route's, the connected LiveView's work is the view's" do
      start()
      {:ok, view, _} = live(build_conn(), "/room/1")
      render_click(view, "work")
      report = FactoryReport.report()

      assert Map.keys(by(report, "custom", "work")) == [@room]
      # http.route and liveview.* rows are about the page itself: no breakdown.
      assert by(report, "http.route", "GET /room/:id") == %{}
      assert by(report, "liveview.event", "FactoryReport.TestLive.Room#work") == %{}
    end

    test "a cut takes breakdown rows before any total" do
      quiet()
      start(max_stream_names: 1_000)
      Attribution.mark({"http.route", "GET /made-up"})

      for i <- 1..200, _ <- 1..i, do: FactoryReport.event("e#{i}")
      Attribution.clear()

      report = FactoryReport.report()
      {totals, breakdowns} = Enum.split_with(report["streams"], &(not is_map_key(&1, "by")))

      assert length(report["streams"]) == 300
      assert length(totals) == 200
      assert length(breakdowns) == 100
      assert report["truncated"]["streams"] == 100
      # Totals first, each part the busiest first.
      assert Enum.take(report["streams"], 200) == totals
      assert hd(totals)["name"] == "e200"
      assert hd(breakdowns)["name"] == "e200"
      assert List.last(breakdowns)["name"] == "e101"
    end

    test "breakdown rows share the kind's room but never take its last quarter" do
      quiet()
      start(max_stream_names: 8)
      Attribution.mark({"http.route", "GET /made-up"})

      for i <- 1..10, do: FactoryReport.event("n#{i}")
      Attribution.clear()

      report = FactoryReport.report()
      custom = Enum.filter(report["streams"], &(&1["kind"] == "custom"))
      {totals, breakdowns} = Enum.split_with(custom, &(not is_map_key(&1, "by")))

      # 8 rows: n1..n3 with their breakdowns (6), then totals only.
      assert Enum.map(breakdowns, & &1["name"]) |> Enum.sort() == ~w(n1 n2 n3)

      assert Enum.map(totals, & &1["name"]) |> Enum.sort() ==
               Enum.sort(["n1", "n2", "n3", "n4", "n5", "(other)"])

      assert %{"count" => 5} = total(report, "custom", "(other)")
    end

    test "nothing is attributed, and nothing raises, when the reporter is not running" do
      assert Attribution.current() == nil
      assert FactoryReport.event("x") == :ok
    end
  end

  describe "log streams and events" do
    test "every level is counted; warning and above are listed, newest first" do
      start()
      Logger.debug("a debug line")
      Logger.info("an info line")
      Logger.info("another info line")
      Logger.warning("disk is nearly full")
      Logger.error("poll failed: timeout")

      report = FactoryReport.report()

      assert total(report, "log", "info") ==
               %{"kind" => "log", "name" => "info", "count" => 2, "errors" => 0, "duration_us" => 0}

      assert %{"count" => 1} = total(report, "log", "debug")
      assert %{"count" => 1} = total(report, "log", "warning")
      assert %{"count" => 1} = total(report, "log", "error")
      assert by(report, "log", "error") == %{}

      assert [error, warning] = report["events"]

      assert Map.drop(error, ["at"]) == %{
               "level" => "error",
               "name" => "FactoryReport.SecondRoundTest",
               "message" => "poll failed: timeout",
               "by" => nil
             }

      assert warning["level"] == "warning"
      assert warning["message"] == "disk is nearly full"
      assert {:ok, at, 0} = DateTime.from_iso8601(error["at"])
      assert DateTime.diff(DateTime.utc_now(), at) in 0..5
      assert error["at"] =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/
      assert report |> Jason.encode!() |> Jason.decode!() == report
    end

    test "an event logged by a LiveView or during a request carries its page" do
      start()
      {:ok, view, _} = live(build_conn(), "/room/1")
      render_click(view, "work")
      get(build_conn(), "/work")

      assert [from_route, from_view] = FactoryReport.report()["events"]
      assert from_route["message"] == "work warning from controller"
      assert from_route["by"] == @route
      assert from_route["name"] == "FactoryReport.TestWork"
      assert from_view["message"] == "work warning from liveview"
      assert from_view["by"] == @room
    end

    test "the list holds the 50 most recent; a message is cut at 300 characters" do
      start()
      for i <- 1..60, do: Logger.warning("w#{i}")
      Logger.error(String.duplicate("é", 1000))

      events = FactoryReport.report()["events"]
      assert length(events) == 50
      assert hd(events)["message"] == String.duplicate("é", 300)
      assert Enum.map(tl(events), & &1["message"]) == for(i <- 60..12//-1, do: "w#{i}")
      assert :ets.info(:factory_report_events, :size) == 50
    end

    test "log_events: false lists nothing and still counts" do
      start(log_events: false)
      Logger.error("not for the report")
      report = FactoryReport.report()

      assert report["events"] == []
      assert %{"count" => 1} = total(report, "log", "error")
      refute Jason.encode!(report) =~ "not for the report"
    end

    test "log_level: sets the floor of the list" do
      start(log_level: :error)
      Logger.warning("below the floor")
      Logger.error("at the floor")
      Logger.critical("above the floor")

      assert ["above the floor", "at the floor"] = Enum.map(FactoryReport.report()["events"], & &1["message"])

      stop_supervised!(FactoryReport)
      start(log_level: :info)
      Logger.info("now info is listed")
      assert [%{"level" => "info", "message" => "now info is listed"}] = FactoryReport.report()["events"]
    end

    test "every :logger message shape becomes text" do
      start()

      :logger.warning("plain erlang string")
      :logger.warning(~c"format ~p and ~s", [%{a: 1}, "text"])
      :logger.warning(%{what: "a map report", n: 1})
      :logger.warning(what: "a keyword report", n: 2)
      :logger.log(:warning, %{n: 3}, %{report_cb: fn %{n: n} -> {~c"callback/1 says ~p", [n]} end})
      :logger.log(:warning, %{n: 4}, %{report_cb: fn %{n: n}, _config -> "callback/2 says #{n}" end})
      :logger.log(:warning, %{n: 5}, %{report_cb: fn _ -> raise "broken callback" end})
      Logger.warning(["io", ?d, ["ata ", ~c"nested"] | " improper"])
      Logger.warning(fn -> {"lazy message", []} end)

      messages = FactoryReport.report()["events"] |> Enum.map(& &1["message"]) |> Enum.reverse()

      assert [
               "plain erlang string",
               "format " <> _,
               map_report,
               keyword_report,
               "callback/1 says 3",
               "callback/2 says 4",
               broken,
               "iodata nested improper",
               "lazy message"
             ] = messages

      assert Enum.at(messages, 1) =~ "text"
      assert map_report =~ "a map report"
      assert keyword_report =~ "a keyword report"
      assert broken =~ "5"
      assert Enum.all?(messages, &(String.valid?(&1) and String.length(&1) <= 300))
    end

    test "Message.text never raises and bounds its work" do
      assert Message.text({:string, "ok"}, %{}, 300) == "ok"
      assert Message.text({:string, [<<255, 254>>, "x"]}, %{}, 300) == "??x"
      assert Message.text({:string, [:not, :chardata]}, %{}, 300) == ""
      assert Message.text({~c"~p ~p", [1]}, %{}, 300) =~ "~p"
      assert Message.text({:report, :not_a_report}, %{}, 300) == ":not_a_report"
      assert Message.text({:report, %{a: self()}}, %{}, 300) =~ "a=#PID"
      assert Message.text(:nonsense, %{}, 300) == ":nonsense"
      assert Message.text({:report, %{}}, %{report_cb: fn _ -> :bad end}, 300) == ""
      assert Message.text({:report, %{k: 1}}, %{report_cb: fn _, _ -> throw(:no) end}, 300) == "k=1"

      # A huge message is not flattened whole: only its head is touched.
      huge = List.duplicate(String.duplicate("a", 1_000), 100_000)
      {us, text} = :timer.tc(fn -> Message.text({:string, huge}, %{}, 300) end)
      assert text == String.duplicate("a", 300)
      assert us < 50_000

      assert Message.text({:string, ["line one\n", "line two  "]}, %{}, :infinity) == "line one\nline two"
    end

    test "the handler never raises, is never removed for it, and goes when the reporter stops" do
      start()
      {:ok, config} = :logger.get_handler_config(:factory_report)

      for garbage <- [
            %{},
            :nope,
            %{level: "x", msg: 1, meta: nil},
            %{level: :warning, msg: {:string, self()}, meta: %{mfa: 7, time: "now"}}
          ] do
        assert LogHandler.log(garbage, config) == :ok
        assert LogHandler.log(garbage, :not_a_config) == :ok
      end

      Logger.warning("still listening")
      assert {:ok, _} = :logger.get_handler_config(:factory_report)
      assert "still listening" in Enum.map(FactoryReport.report()["events"], & &1["message"])

      stop_supervised!(FactoryReport)
      assert {:error, {:not_found, :factory_report}} = :logger.get_handler_config(:factory_report)
      assert Logger.warning("nobody listens, nothing breaks") == :ok
    end

    test "the handler is back after the tracker restarts, and the events survive" do
      start()
      Logger.warning("before the restart")

      tracker = Process.whereis(Tracker)
      ref = Process.monitor(tracker)
      Process.exit(tracker, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      await_restart(tracker, 10_000)

      Logger.warning("after the restart")

      assert ["after the restart", "before the restart"] =
               FactoryReport.report()["events"]
               |> Enum.map(& &1["message"])
               |> Enum.filter(&(&1 =~ "restart"))
    end
  end

  defp await_restart(old, rounds) do
    Supervisor.count_children(FactoryReport)

    case Process.whereis(Tracker) do
      pid when is_pid(pid) and pid != old -> Tracker.sync()
      _ when rounds == 0 -> flunk("the tracker did not come back")
      _ -> await_restart(old, rounds - 1)
    end
  end

  describe "JSONFormatter" do
    test "one object per line with exactly the seven keys, in order" do
      line =
        JSONFormatter.format(
          event(:warning, {:string, ["disk ", "full"]}, %{
            mfa: {Blog.Poller, :run, 1},
            request_id: "F8abc",
            user_id: 42,
            file: "lib/x.ex"
          }),
          %{app: :blog}
        )

      binary = IO.iodata_to_binary(line)

      assert binary ==
               ~s|{"time":"2026-11-19T08:40:02.123Z","level":"warning","msg":"disk full","app":"blog","module":"Blog.Poller","request_id":"F8abc","page":null}\n|

      assert decode(line) |> Map.keys() |> Enum.sort() == ~w(app level module msg page request_id time)
    end

    test "nulls where there is nothing to say; works without the reporter" do
      assert decode(JSONFormatter.format(event(:info, {:string, "hi"}), %{})) == %{
               "time" => "2026-11-19T08:40:02.123Z",
               "level" => "info",
               "msg" => "hi",
               "app" => nil,
               "module" => nil,
               "request_id" => nil,
               "page" => nil
             }
    end

    test "metadata: whitelists further keys; reserved names cannot be overwritten" do
      meta = %{trace_id: "t-1", attempt: 3, pid: self(), secret: "no", level: "fake", blob: <<255>>}
      config = %{metadata: [:trace_id, :attempt, :pid, :level, :blob, :absent]}
      decoded = decode(JSONFormatter.format(event(:error, {:string, "x"}, meta), config))

      assert decoded["trace_id"] == "t-1"
      assert decoded["attempt"] == 3
      assert decoded["pid"] =~ "#PID<"
      assert decoded["blob"] == "<<255>>"
      assert decoded["level"] == "error"
      refute Map.has_key?(decoded, "secret")
      refute Map.has_key?(decoded, "absent")
    end

    test "every message shape, and messages that are not text, still make one valid line" do
      shapes = [
        {:string, <<255, 0, "bin">>},
        {:string, "two\nlines \"quoted\""},
        {~c"~p", [self()]},
        {~c"~p ~p", [:too_few]},
        {:report, %{pid: self(), ref: make_ref()}},
        {:report, [a: 1]},
        :not_a_message
      ]

      for msg <- shapes do
        decoded = decode(JSONFormatter.format(event(:error, msg), %{}))
        assert is_binary(decoded["msg"])
      end

      assert decode(JSONFormatter.format(event(:error, {:string, "two\nlines"}), %{}))["msg"] == "two\nlines"
    end

    test "an event that is not an event becomes a minimal line" do
      for garbage <- [%{}, :nope, %{level: :info}, %{level: 5, msg: 1, meta: 2}] do
        for config <- [%{}, :not_a_config, %{metadata: :nope}] do
          decoded = decode(JSONFormatter.format(garbage, config))
          assert decoded["msg"] == "(unformattable log event)"
          assert is_binary(decoded["level"])
        end
      end
    end

    test "check_config takes a map" do
      assert JSONFormatter.check_config(%{}) == :ok
      assert JSONFormatter.check_config(%{metadata: [:a]}) == :ok
      assert {:error, _} = JSONFormatter.check_config([])
    end

    test "through :logger: app from the reporter, page from the process that logged" do
      start()
      test = self()

      :ok =
        :logger.add_handler(:factory_report_test_sink, FactoryReport.TestSink, %{
          level: :warning,
          formatter: {JSONFormatter, %{}},
          config: %{pid: test}
        })

      on_exit(fn -> :logger.remove_handler(:factory_report_test_sink) end)

      Logger.warning("from the test")
      assert_receive {:line, line}
      assert %{"msg" => "from the test", "app" => "factory_report", "page" => nil} = decode(line)
      assert decode(line)["module"] == "FactoryReport.SecondRoundTest"

      {:ok, view, _} = live(build_conn(), "/room/1")
      render_click(view, "work")
      assert_receive {:line, line}

      assert %{
               "msg" => "work warning from liveview",
               "level" => "warning",
               "page" => "FactoryReport.TestLive.Room",
               "request_id" => "req-liveview",
               "module" => "FactoryReport.TestWork"
             } = decode(line)

      get(build_conn(), "/work")
      assert_receive {:line, line}
      assert %{"msg" => "work warning from controller", "page" => "GET /work"} = decode(line)
    end
  end
end
