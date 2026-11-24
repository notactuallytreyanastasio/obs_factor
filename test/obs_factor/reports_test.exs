defmodule ObsFactor.ReportsTest do
  # The pure parts on the contract's example document, and the collector
  # against a fake sub-app on a real socket.
  use ExUnit.Case, async: true

  alias ObsFactor.{Fixtures, Reports}

  defmodule FakeApp do
    # `state` is an Agent holding the body `/report` serves and every
    # authorization header it was asked with.
    import Plug.Conn

    def init(state), do: state

    def call(%Plug.Conn{path_info: ["report"]} = conn, state) do
      auth = get_req_header(conn, "authorization")
      Agent.update(state, &%{&1 | asked_with: [auth | &1.asked_with]})
      json(conn, 200, Agent.get(state, & &1.body))
    end

    def call(%Plug.Conn{path_info: ["guarded"]} = conn, _state) do
      case get_req_header(conn, "authorization") do
        ["Bearer s3cret"] -> json(conn, 200, Fixtures.report_body())
        _ -> json(conn, 401, ~s({"error":"unauthorized"}))
      end
    end

    def call(%Plug.Conn{path_info: ["v2"]} = conn, _state) do
      json(conn, 200, Jason.encode!(%{Fixtures.report_doc() | "factory_report" => 2}))
    end

    def call(%Plug.Conn{path_info: ["not-json"]} = conn, _state) do
      json(conn, 200, ~s({"factory_report": 1, "runtime": ))
    end

    def call(%Plug.Conn{path_info: ["broken"]} = conn, _state), do: json(conn, 500, "{}")

    def call(%Plug.Conn{path_info: ["moved"]} = conn, _state) do
      conn |> put_resp_header("location", "/report") |> send_resp(302, "")
    end

    def call(%Plug.Conn{path_info: ["slow"]} = conn, _state) do
      # Longer than the collector's 2 s timeout.
      Process.sleep(2_500)
      json(conn, 200, Fixtures.report_body())
    end

    def call(conn, _state), do: json(conn, 404, ~s({"error":"not found"}))

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, body)
    end
  end

  defp validated!(doc) do
    assert {:ok, reading} = Reports.validate(doc)
    reading
  end

  defp at(reading, at_ms), do: Map.put(reading, :at_ms, at_ms)

  defp stream!(streams, name), do: Enum.find(streams, &(&1.name == name)) || flunk("no #{name}")

  describe "validate" do
    test "the contract's example" do
      reading = validated!(Fixtures.report_doc())

      assert reading.app == "blog"

      assert reading.runtime == %{
               kind: "beam",
               versions: %{
                 "otp" => "28",
                 "elixir" => "1.19.5",
                 "phoenix" => "1.7.19",
                 "phoenix_live_view" => "1.0.3",
                 "app" => "0.1.0"
               },
               uptime_s: 12345,
               gauges: %{"memory.total" => 123_456_789, "process.count" => 812, "run_queue" => 0},
               counters: %{"reductions" => 99_887_766, "io.out_bytes" => 123_456}
             }

      assert reading.units == [
               %{
                 kind: "liveview",
                 name: "BlogWeb.PostLive",
                 route: "/post/:slug",
                 count: 3,
                 gauges: %{"memory" => 812_345, "message_queue" => 0},
                 members: [
                   %{
                     id: "9f2c1a",
                     label: "/post/the-factory-must-grow",
                     since: "2026-11-19T07:31:02Z",
                     gauges: %{"memory" => 301_234, "message_queue" => 0},
                     counters: %{"events" => 14}
                   }
                 ]
               }
             ]

      assert length(reading.streams) == 4

      assert stream!(reading.streams, "GET /post/:slug") == %{
               kind: "http.route",
               name: "GET /post/:slug",
               by: nil,
               count: 4410,
               errors: 2,
               duration_us: 98_765_432
             }

      assert reading.events == []
      assert reading.truncated == %{units: 0, members: 0, streams: 0, tables: 0}
    end

    test "an unknown version fails with the number" do
      doc = Fixtures.report_doc()

      assert Reports.validate(%{doc | "factory_report" => 2}) ==
               {:error, "unknown factory_report version 2"}

      assert Reports.validate(Map.delete(doc, "factory_report")) ==
               {:error, "factory_report is missing"}

      assert Reports.validate(%{doc | "factory_report" => "1"}) ==
               {:error, ~s(factory_report is not a number: "1")}
    end

    test "a wrong shape fails with what is wrong and where" do
      doc = Fixtures.report_doc()
      error = fn doc -> elem({:error, _} = Reports.validate(doc), 1) end

      assert error.([1, 2]) == "report is not a JSON object"
      assert error.(Map.delete(doc, "runtime")) == "runtime is missing"
      assert error.(%{doc | "runtime" => []}) == "runtime is not an object"
      assert error.(put_in(doc, ["runtime", "uptime_s"], "long")) =~ "runtime.uptime_s is not a"
      assert error.(put_in(doc, ["runtime", "uptime_s"], -1)) == "runtime.uptime_s is negative"
      assert error.(put_in(doc, ["runtime", "gauges"], [1])) == "runtime.gauges is not an object"
      assert error.(%{doc | "units" => %{}}) == "units is not a list"
      assert error.(%{doc | "units" => ["x"]}) == "units[0] is not an object"

      assert error.(put_in(doc, ["units", Access.at(0), "count"], nil)) ==
               "units[0].count is missing"

      assert error.(put_in(doc, ["units", Access.at(0), "members"], [%{"id" => 7}])) ==
               "units[0].members[0].id is not a string"

      assert error.(%{doc | "streams" => "none"}) == "streams is not a list"

      assert error.(put_in(doc, ["streams", Access.at(1), "count"], "many")) ==
               "streams[1].count is not a number"

      assert error.(put_in(doc, ["streams", Access.at(2), "name"], nil)) ==
               "streams[2].name is missing"

      assert error.(%{doc | "truncated" => 3}) == "truncated is not an object"
    end

    test "a reporter with nothing inside may leave units, streams and truncated out" do
      doc = Map.drop(Fixtures.report_doc(), ["units", "streams", "truncated", "app", "at"])
      doc = update_in(doc, ["runtime"], &Map.drop(&1, ["versions", "gauges", "counters"]))

      reading = validated!(doc)
      assert reading.units == []
      assert reading.streams == []
      assert reading.truncated == %{units: 0, members: 0, streams: 0, tables: 0}
      assert reading.runtime.gauges == %{}
      assert reading.runtime.counters == %{}
      assert reading.runtime.versions == %{}
    end

    test "gauge and counter values that are not numbers are ignored" do
      doc =
        Fixtures.report_doc()
        |> put_in(["runtime", "gauges", "mood"], "fine")
        |> put_in(["runtime", "gauges", "nested"], %{"a" => 1})
        |> put_in(["runtime", "counters", "nothing"], nil)
        |> put_in(["runtime", "versions", "weird"], [1])
        |> put_in(["units", Access.at(0), "gauges", "x"], true)

      reading = validated!(doc)
      assert Map.keys(reading.runtime.gauges) == ["memory.total", "process.count", "run_queue"]
      assert Map.keys(reading.runtime.counters) == ["io.out_bytes", "reductions"]
      refute Map.has_key?(reading.runtime.versions, "weird")
      assert hd(reading.units).gauges == %{"memory" => 812_345, "message_queue" => 0}
    end

    test "a reporter that does not bound itself is bounded here, and the cut is counted" do
      long = String.duplicate("n", 500)
      member = fn i -> %{"id" => "m#{i}", "label" => long} end

      unit = fn i ->
        %{
          "kind" => "room",
          "name" => "#{long}#{i}",
          "count" => 30,
          "members" => Enum.map(1..30, member)
        }
      end

      stream = fn i ->
        %{"kind" => "custom", "name" => "s#{i}", "count" => i, "errors" => 0, "duration_us" => 0}
      end

      gauges = Map.new(1..150, &{"g#{String.pad_leading("#{&1}", 3, "0")}", &1})

      doc =
        Fixtures.report_doc()
        |> Map.put("units", Enum.map(1..120, unit))
        |> Map.put("streams", Enum.map(1..350, stream))
        |> Map.put("truncated", %{"units" => 5, "members" => 1, "streams" => 2})
        |> put_in(["runtime", "gauges"], gauges)

      reading = validated!(doc)

      assert length(reading.units) == 100
      assert Enum.all?(reading.units, &(length(&1.members) == 20))
      assert Enum.all?(reading.units, &(String.length(&1.name) == 120))

      assert reading.units |> hd() |> Map.fetch!(:members) |> hd() |> Map.fetch!(:label) ==
               String.duplicate("n", 120)

      # The 300 busiest by count: s51..s350.
      assert length(reading.streams) == 300
      assert reading.streams |> Enum.map(& &1.count) |> Enum.min() == 51

      assert map_size(reading.runtime.gauges) == 100
      assert Map.has_key?(reading.runtime.gauges, "g001")
      refute Map.has_key?(reading.runtime.gauges, "g101")

      # 5 + 20 units, 1 + 100 * 10 members (of the units kept), 2 + 50 streams.
      assert reading.truncated == %{units: 25, members: 1001, streams: 52, tables: 0}
    end

    test "by on a stream: a breakdown row and its total are two rows" do
      reading = validated!(Fixtures.liveapp_doc())
      repo = Enum.filter(reading.streams, &(&1.name == "Liveapp.Repo"))

      assert repo == [
               %{
                 kind: "db.query",
                 name: "Liveapp.Repo",
                 by: nil,
                 count: 40,
                 errors: 0,
                 duration_us: 9000
               },
               %{
                 kind: "db.query",
                 name: "Liveapp.Repo",
                 by: %{kind: "liveview", name: "LiveappWeb.CounterLive"},
                 count: 30,
                 errors: 0,
                 duration_us: 7000
               }
             ]

      # The same row twice is still one row.
      doc = update_in(Fixtures.liveapp_doc(), ["streams"], &(&1 ++ [Enum.at(&1, 2)]))
      assert length(validated!(doc).streams) == 5

      long = String.duplicate("k", 200)

      doc =
        put_in(Fixtures.liveapp_doc(), ["streams", Access.at(2), "by"], %{
          "kind" => long,
          "name" => long,
          "pid" => "ignored"
        })

      by = Enum.at(validated!(doc).streams, 2).by
      assert by == %{kind: String.duplicate("k", 120), name: String.duplicate("k", 120)}
    end

    test "a by of the wrong shape fails the report, saying where" do
      doc = Fixtures.liveapp_doc()
      error = fn doc -> elem({:error, _} = Reports.validate(doc), 1) end
      by = fn value -> put_in(doc, ["streams", Access.at(2), "by"], value) end

      assert error.(by.("LiveappWeb.CounterLive")) == "streams[2].by is not an object"
      assert error.(by.(["liveview", "x"])) == "streams[2].by is not an object"
      assert error.(by.(%{"kind" => "liveview"})) == "streams[2].by.name is missing"
      assert error.(by.(%{"kind" => 1, "name" => "x"})) == "streams[2].by.kind is not a string"
    end

    test "events: as reported, newest first, at most 50, strings cut" do
      assert validated!(Fixtures.liveapp_doc()).events == [
               %{
                 at: "2026-11-19T08:12:33Z",
                 level: "warning",
                 name: "LiveappWeb.RoomLive",
                 message: "room 42 is getting loud",
                 by: %{kind: "liveview", name: "LiveappWeb.RoomLive"}
               }
             ]

      event = fn i ->
        %{
          "at" => "2026-11-19T08:12:33Z",
          "level" => "error",
          "name" => String.duplicate("M", 200),
          "message" => "#{i} " <> String.duplicate("x", 400)
        }
      end

      doc = Map.put(Fixtures.liveapp_doc(), "events", Enum.map(1..60, event))
      events = validated!(doc).events

      assert length(events) == 50
      assert Enum.map(events, &hd(String.split(&1.message))) == Enum.map(1..50, &"#{&1}")
      assert Enum.all?(events, &(String.length(&1.message) == 300))
      assert Enum.all?(events, &(String.length(&1.name) == 120))
      assert Enum.all?(events, &(&1.by == nil))

      # name and by are optional.
      doc =
        Map.put(Fixtures.liveapp_doc(), "events", [
          %{"at" => "t", "level" => "l", "message" => ""}
        ])

      assert validated!(doc).events == [%{at: "t", level: "l", name: nil, message: "", by: nil}]
    end

    test "a malformed event fails the report, saying where" do
      doc = Fixtures.liveapp_doc()
      error = fn doc -> elem({:error, _} = Reports.validate(doc), 1) end
      event = fn key, value -> put_in(doc, ["events", Access.at(0), key], value) end

      assert error.(%{doc | "events" => %{}}) == "events is not a list"
      assert error.(%{doc | "events" => ["boom"]}) == "events[0] is not an object"
      assert error.(event.("at", nil)) == "events[0].at is missing"
      assert error.(event.("at", 1_795_000_000)) == "events[0].at is not a string"
      assert error.(event.("level", nil)) == "events[0].level is missing"
      assert error.(event.("message", nil)) == "events[0].message is missing"
      assert error.(event.("message", %{"a" => 1})) == "events[0].message is not a string"
      assert error.(event.("name", 7)) == "events[0].name is not a string"
      assert error.(event.("by", "x")) == "events[0].by is not an object"
      assert error.(event.("by", %{"name" => "x"})) == "events[0].by.kind is missing"
    end

    test "the real reporter's document: a null route, gauges and counters we do not name" do
      reading = validated!(Fixtures.liveapp_doc())

      assert Enum.map(reading.units, &{&1.kind, &1.name, &1.route, &1.count}) == [
               {"liveview", "LiveappWeb.CounterLive", "/", 2},
               {"channel", "room:*", nil, 1}
             ]

      assert reading.runtime.gauges["port.limit"] == 65536
      assert reading.runtime.gauges["scheduler.utilization"] == 0.0334
      assert map_size(reading.runtime.gauges) == 16
      assert reading.runtime.counters["report.handler_errors"] == 0
      assert map_size(reading.runtime.counters) == 7
      assert length(reading.streams) == 5
      assert reading.truncated == %{units: 0, members: 0, streams: 0, tables: 0}
    end

    test "over 300 streams: totals are kept before breakdown rows" do
      total = fn i ->
        %{"kind" => "custom", "name" => "t#{i}", "count" => i, "errors" => 0, "duration_us" => 0}
      end

      part = fn i ->
        total.(i)
        |> Map.put("count", 10_000 + i)
        |> Map.put("by", %{"kind" => "u", "name" => "x"})
      end

      doc =
        Map.put(
          Fixtures.report_doc(),
          "streams",
          Enum.map(1..200, part) ++ Enum.map(1..200, total)
        )

      reading = validated!(doc)
      {totals, parts} = Enum.split_with(reading.streams, &(&1.by == nil))

      # Every total, though each is less busy than every breakdown row, and
      # the 100 busiest breakdown rows.
      assert length(totals) == 200
      assert parts |> Enum.map(& &1.count) |> Enum.sort() == Enum.to_list(10_101..10_200)
      assert reading.truncated.streams == 100
    end

    test "a stream reported twice is one row" do
      doc = update_in(Fixtures.report_doc(), ["streams"], &(&1 ++ [hd(&1)]))
      assert length(validated!(doc).streams) == 4
    end
  end

  describe "the cluster section" do
    defp clustered(conns, globals \\ []) do
      Map.put(Fixtures.report_doc(), "cluster", %{
        "node" => "app@10.0.0.2",
        "distributed" => true,
        "connections" => conns,
        "globals" => globals
      })
    end

    test "is optional: a reporter from before it has none" do
      assert validated!(Fixtures.report_doc()).cluster == nil
    end

    test "is read and bounded, and a connection's byte counts become rates" do
      conn = fn i, o -> %{"node" => "app@10.0.0.3", "kind" => "visible", "in_bytes" => i, "out_bytes" => o, "send_queue_bytes" => 0} end
      first = clustered([conn.(1_000, 4_000)], [%{"name" => "Marginalia.Runs", "node" => "app@10.0.0.3"}]) |> validated!()
      assert first.cluster.node == "app@10.0.0.2"
      assert [%{name: "Marginalia.Runs", node: "app@10.0.0.3"}] = first.cluster.globals

      {d1, st} = Reports.step(Reports.new_node(), {:ok, first}, 0)
      assert [%{in_bps: nil, out_bps: nil}] = d1.cluster.connections

      second = clustered([conn.(3_000, 5_000)]) |> validated!()
      {d2, _} = Reports.step(st, {:ok, second}, 2_000)
      assert [%{in_bps: 1000.0, out_bps: 500.0, send_queue_bytes: 0}] = d2.cluster.connections

      many = for i <- 1..100, do: conn.(i, i)
      assert length(validated!(clustered(many)).cluster.connections) == 64
    end

    test "a cluster that is not an object fails the report" do
      assert {:error, "cluster is not an object"} = Reports.validate(Map.put(Fixtures.report_doc(), "cluster", []))
    end
  end

  describe "replicas" do
    defp member(streams, units, ok \\ true) do
      if ok do
        %{ok: true, error: nil, at: ~U[2026-11-22 00:00:00Z], runtime: %{}, units: units, streams: streams, events: [], cluster: nil}
      else
        %{ok: false, error: "connection refused", at: nil}
      end
    end

    defp s(name, count, rate, avg) do
      %{kind: "http.route", name: name, by: nil, count: count, rate: rate, err_rate: 0.0, avg_ms: avg}
    end

    defp u(name, count), do: %{kind: "liveview", name: name, route: nil, count: count, gauges: %{}, members: []}

    test "each node counts its own share: the node's streams and units are the sum, every member is listed" do
      data =
        Reports.combine([
          {"10.0.0.3", member([s("GET /", 30, 3.0, 20.0)], [u("Show", 2)])},
          {"10.0.0.10", member([], [], false)},
          {"10.0.0.2", member([s("GET /", 10, 1.0, 40.0), s("GET /a", 1, nil, nil)], [u("Show", 1), u("Index", 4)])}
        ])

      # the lead is the first that answered, by address (10.0.0.2 < 10.0.0.3 < 10.0.0.10)
      assert Enum.map(data.members, & &1.address) == ~w(10.0.0.2 10.0.0.3 10.0.0.10)
      assert %{ok: false, error: "connection refused"} = List.last(data.members)

      root = Enum.find(data.streams, &(&1.name == "GET /"))
      assert root.count == 40 and root.rate == 4.0
      # weighted by rate: (20 * 3 + 40 * 1) / 4
      assert root.avg_ms == 25.0
      # one node does not know /a's rate yet: neither does the sum
      assert Enum.find(data.streams, &(&1.name == "GET /a")).rate == nil

      assert [%{name: "Index", count: 4}, %{name: "Show", count: 3}] = data.units
    end

    test "nobody answered: the first member's error stands for the node" do
      data = Reports.combine([{"10.0.0.3", member([], [], false)}, {"10.0.0.2", member([], [], false)}])
      assert %{ok: false, error: "connection refused", members: [_, _]} = data
    end

    test "a name with one address, an address, or no name at all is read as given" do
      assert Reports.expand("http://127.0.0.1:9568/report") == [{nil, "http://127.0.0.1:9568/report"}]
      assert Reports.expand("http://localhost:9568/report") == [{nil, "http://localhost:9568/report"}]
      assert Reports.expand("http://no-such-host.invalid:9568/report") == [{nil, "http://no-such-host.invalid:9568/report"}]
    end
  end

  describe "parse" do
    test "the fixture body" do
      assert {:ok, %{app: "blog"}} = Reports.parse(Fixtures.report_body())
    end

    test "malformed JSON says where, not what" do
      assert Reports.parse("{\"factory_report\": 1, ") == {:error, "malformed JSON at byte 22"}
      assert Reports.parse("") == {:error, "malformed JSON at byte 0"}
      assert Reports.parse("<html>502</html>") == {:error, "malformed JSON at byte 0"}
    end
  end

  describe "rates between two reads" do
    setup do
      first = Fixtures.report_doc() |> validated!() |> at(1_000_000)
      second = Fixtures.report_doc_later() |> validated!() |> at(1_005_000)
      {:ok, first: first, second: second}
    end

    test "one read: every rate is nil", %{first: first} do
      rates = Reports.rates(nil, first)

      assert rates.restart == false
      assert rates.runtime == %{"reductions" => nil, "io.out_bytes" => nil}

      assert stream!(rates.streams, "GET /post/:slug") == %{
               kind: "http.route",
               name: "GET /post/:slug",
               by: nil,
               count: 4410,
               rate: nil,
               err_rate: nil,
               avg_ms: nil
             }
    end

    test "two reads of the same process", %{first: first, second: second} do
      rates = Reports.rates(first, second)

      assert rates.restart == false
      assert rates.runtime == %{"reductions" => 51_200.0, "io.out_bytes" => 1_000.0}

      assert stream!(rates.streams, "GET /post/:slug") == %{
               kind: "http.route",
               name: "GET /post/:slug",
               by: nil,
               count: 4416,
               rate: 1.2,
               err_rate: 0.0,
               avg_ms: 22.4
             }

      assert %{rate: 10.0, err_rate: +0.0, avg_ms: 0.5} = stream!(rates.streams, "Blog.Repo")

      assert %{rate: 0.2, err_rate: 0.2, avg_ms: 2000.0} =
               stream!(rates.streams, "api.deepseek.com")

      # Nothing happened in the tick: a rate of zero and no average.
      assert %{count: 120, rate: +0.0, err_rate: +0.0, avg_ms: nil} =
               stream!(rates.streams, "BlogWeb.PostLive#like")
    end

    test "a smaller uptime is a restart: every rate nil", %{first: first, second: second} do
      restarted = put_in(second.runtime.uptime_s, 3)
      rates = Reports.rates(first, restarted)

      assert rates.restart == true
      assert rates.runtime == %{"reductions" => nil, "io.out_bytes" => nil}
      assert Enum.all?(rates.streams, &(&1.rate == nil and &1.err_rate == nil))
      assert Enum.all?(rates.streams, &(&1.avg_ms == nil))
      # What the process says now is still shown.
      assert stream!(rates.streams, "GET /post/:slug").count == 4416
    end

    test "a counter going backwards is a restart", %{first: first, second: second} do
      back = put_in(second.runtime.counters["reductions"], 5)
      assert %{restart: true, runtime: %{"io.out_bytes" => nil}} = Reports.rates(first, back)
    end

    test "a stream total going backwards is a restart", %{first: first, second: second} do
      for key <- [:count, :errors, :duration_us] do
        streams =
          Enum.map(second.streams, fn s ->
            if s.name == "api.deepseek.com", do: Map.put(s, key, 0), else: s
          end)

        rates = Reports.rates(first, %{second | streams: streams})
        assert rates.restart == true, "#{key} went backwards"
        assert stream!(rates.streams, "GET /post/:slug").rate == nil
      end
    end

    test "the read after a restart has rates again", %{first: first, second: second} do
      restarted = put_in(second.runtime.uptime_s, 3)
      assert Reports.rates(first, restarted).restart

      third =
        restarted
        |> put_in([:runtime, :uptime_s], 8)
        |> update_in([:runtime, :counters, "reductions"], &(&1 + 500))
        |> at(1_010_000)

      assert %{restart: false, runtime: %{"reductions" => 100.0}} =
               Reports.rates(restarted, third)
    end

    test "a stream that was not there before started from zero", %{first: first, second: second} do
      new = %{
        kind: "custom",
        name: "gif.rendered",
        by: nil,
        count: 10,
        errors: 5,
        duration_us: 30_000
      }

      rates = Reports.rates(first, %{second | streams: [new | second.streams]})

      assert %{rate: 2.0, err_rate: 1.0, avg_ms: 3.0} = stream!(rates.streams, "gif.rendered")
    end

    test "unless the previous read was cut: then it may have been below the cut", %{
      first: first,
      second: second
    } do
      first = put_in(first.truncated.streams, 12)

      new = %{
        kind: "custom",
        name: "gif.rendered",
        by: nil,
        count: 10,
        errors: 5,
        duration_us: 30_000
      }

      rates = Reports.rates(first, %{second | streams: [new | second.streams]})

      assert %{rate: nil, err_rate: nil, avg_ms: nil} = stream!(rates.streams, "gif.rendered")
      assert stream!(rates.streams, "GET /post/:slug").rate == 1.2
      assert rates.restart == false
    end

    test "a counter that was not there before has no rate yet", %{first: first, second: second} do
      second = put_in(second.runtime.counters["gc.count"], 40)
      rates = Reports.rates(first, second)

      assert rates.runtime["gc.count"] == nil
      assert rates.runtime["reductions"] == 51_200.0
    end

    test "the real reporter's document, read twice: a breakdown row has its own rates" do
      first = Fixtures.liveapp_doc() |> validated!() |> at(1_000_000)
      second = Fixtures.liveapp_doc_later() |> validated!() |> at(1_005_000)
      rates = Reports.rates(first, second)

      assert rates.restart == false
      assert rates.runtime["reductions"] == 10_000.0
      assert rates.runtime["report.handler_errors"] == 0.0
      assert map_size(rates.runtime) == 7

      assert Enum.filter(rates.streams, &(&1.name == "Liveapp.Repo")) == [
               %{
                 kind: "db.query",
                 name: "Liveapp.Repo",
                 by: nil,
                 count: 50,
                 rate: 2.0,
                 err_rate: 0.0,
                 avg_ms: 0.2
               },
               %{
                 kind: "db.query",
                 name: "Liveapp.Repo",
                 by: %{kind: "liveview", name: "LiveappWeb.CounterLive"},
                 count: 40,
                 rate: 2.0,
                 err_rate: 0.0,
                 avg_ms: 0.2
               }
             ]

      assert %{kind: "log", count: 3, rate: 0.2, avg_ms: +0.0} = stream!(rates.streams, "warning")
    end

    test "a breakdown row going backwards is a restart, its total untouched or not" do
      first = Fixtures.liveapp_doc() |> validated!() |> at(1_000_000)
      second = Fixtures.liveapp_doc_later() |> validated!() |> at(1_005_000)

      streams =
        Enum.map(second.streams, fn s -> if s.by, do: %{s | count: 1}, else: s end)

      assert Reports.rates(first, %{second | streams: streams}).restart == true
    end

    test "a new breakdown row of a total that was there starts from zero" do
      first = Fixtures.liveapp_doc() |> validated!() |> at(1_000_000)
      second = Fixtures.liveapp_doc_later() |> validated!() |> at(1_005_000)

      new = %{
        kind: "db.query",
        name: "Liveapp.Repo",
        by: %{kind: "http.route", name: "GET /"},
        count: 5,
        errors: 0,
        duration_us: 1_000
      }

      rates = Reports.rates(first, %{second | streams: second.streams ++ [new]})
      assert %{rate: 1.0, avg_ms: 0.2} = Enum.find(rates.streams, &(&1.by == new.by))
      assert rates.restart == false
    end

    test "uptime far behind our own clock is a restart, though nothing went backwards", %{
      first: first,
      second: second
    } do
      # Read again 100 s later; the process says it is 1 s older than it was,
      # and every total is higher: it restarted and has caught up.
      short = second |> put_in([:runtime, :uptime_s], first.runtime.uptime_s + 1) |> at(1_100_000)
      assert %{restart: true, runtime: %{"reductions" => nil}} = Reports.rates(first, short)

      # Both conditions must hold. Less than half, but under 10 s short: a
      # normal tick with a slow answer (5 s here, 0 s there).
      same = second |> put_in([:runtime, :uptime_s], first.runtime.uptime_s) |> at(1_005_000)
      assert Reports.rates(first, same).restart == false

      # 19 s here, 9 s there: exactly 10 s short and less than half.
      edge = second |> put_in([:runtime, :uptime_s], first.runtime.uptime_s + 9) |> at(1_019_000)
      assert Reports.rates(first, edge).restart == true

      # 19 s here, 10 s there: 9 s short.
      near = second |> put_in([:runtime, :uptime_s], first.runtime.uptime_s + 10) |> at(1_019_000)
      assert Reports.rates(first, near).restart == false

      # 100 s here, 60 s there: 40 s short but more than half (a paused
      # machine, a slow clock): the same process.
      slow = second |> put_in([:runtime, :uptime_s], first.runtime.uptime_s + 60) |> at(1_100_000)
      assert %{restart: false, runtime: %{"reductions" => 2_560.0}} = Reports.rates(first, slow)
    end

    test "two reads at the same instant give no rates", %{first: first, second: second} do
      rates = Reports.rates(first, at(second, first.at_ms))
      assert rates.restart == false
      assert rates.runtime["reductions"] == nil
    end
  end

  describe "step" do
    test "a failed read keeps when the last good one was, and what it said for the next" do
      {:ok, first} = Reports.validate(Fixtures.report_doc())
      {:ok, second} = Reports.validate(Fixtures.report_doc_later())
      t0 = Fixtures.now_ms()

      assert {%{ok: false, error: "connection refused", at: nil}, state} =
               Reports.step(Reports.new_node(), {:error, "connection refused"}, t0 - 10_000)

      assert {%{ok: true, error: nil, at: at} = data, state} =
               Reports.step(state, {:ok, first}, t0 - 10_000)

      assert at == DateTime.from_unix!(t0 - 10_000, :millisecond)
      assert data.runtime.rates == %{"reductions" => nil, "io.out_bytes" => nil}
      refute Map.has_key?(data.runtime, :counters)

      assert {failed, state} = Reports.step(state, {:error, "timed out"}, t0 - 5_000)
      assert failed == %{ok: false, error: "timed out", at: at}

      # Still the same process: the rate is over the ten seconds between the
      # two good reads.
      assert {%{ok: true, restart: false} = data, _} = Reports.step(state, {:ok, second}, t0)
      assert data.runtime.rates["reductions"] == 25_600.0
      assert data.at == DateTime.from_unix!(t0, :millisecond)
    end
  end

  describe "the collector over HTTP" do
    setup do
      state =
        start_supervised!({Agent, fn -> %{body: Fixtures.report_body(), asked_with: []} end})

      server =
        start_supervised!(
          {Bandit,
           plug: {FakeApp, state},
           port: 0,
           ip: :loopback,
           startup_log: false,
           thousand_island_options: [shutdown_timeout: 100]}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, url: "http://127.0.0.1:#{port}", app: state}
    end

    defp collect!(state) do
      assert {:ok, data, state} = Reports.collect(state)
      {data, state}
    end

    test "a read, then a second read with rates", %{url: url, app: app} do
      {data, state} = collect!(Reports.init_state(targets: [{"blog", url <> "/report"}]))

      assert %{"blog" => %{ok: true, error: nil, at: %DateTime{}} = first} = data
      assert first.runtime.kind == "beam"
      assert first.runtime.uptime_s == 12345
      assert first.runtime.gauges["memory.total"] == 123_456_789
      assert first.runtime.rates == %{"reductions" => nil, "io.out_bytes" => nil}
      assert [%{kind: "liveview", count: 3, members: [%{id: "9f2c1a"}]}] = first.units
      assert Enum.all?(first.streams, &(&1.rate == nil))
      assert Agent.get(app, & &1.asked_with) == [[]]

      Agent.update(app, &%{&1 | body: Jason.encode!(Fixtures.report_doc_later())})
      # As if the first read had been five seconds ago.
      state = update_in(state.nodes["blog"].prev.at_ms, &(&1 - 5_000))
      {data, _state} = collect!(state)

      assert %{"blog" => %{ok: true, restart: false} = second} = data
      assert_in_delta second.runtime.rates["reductions"], 51_200.0, 1_000.0
      assert_in_delta stream!(second.streams, "GET /post/:slug").rate, 1.2, 0.05
      assert stream!(second.streams, "GET /post/:slug").avg_ms == 22.4
      assert stream!(second.streams, "BlogWeb.PostLive#like").avg_ms == nil
    end

    test "a restart between two reads nulls that read's rates", %{url: url, app: app} do
      {_, state} = collect!(Reports.init_state(targets: [{"blog", url <> "/report"}]))
      state = update_in(state.nodes["blog"].prev.at_ms, &(&1 - 5_000))

      restarted = put_in(Fixtures.report_doc_later(), ["runtime", "uptime_s"], 2)
      Agent.update(app, &%{&1 | body: Jason.encode!(restarted)})
      {data, _} = collect!(state)

      assert %{ok: true, restart: true} = data["blog"]
      assert data["blog"].runtime.uptime_s == 2
      assert data["blog"].runtime.rates == %{"reductions" => nil, "io.out_bytes" => nil}
      assert Enum.all?(data["blog"].streams, &(&1.rate == nil and &1.avg_ms == nil))
    end

    test "every way one node's report fails, next to one that works", %{url: url} do
      targets = [
        {"good", url <> "/report"},
        {"v2", url <> "/v2"},
        {"not-json", url <> "/not-json"},
        {"broken", url <> "/broken"},
        {"moved", url <> "/moved"},
        {"guarded", url <> "/guarded"},
        {"missing", url <> "/nothing-here"},
        {"refused", "http://127.0.0.1:1/report"},
        {"slow", url <> "/slow"}
      ]

      {data, state} = collect!(Reports.init_state(targets: targets))

      assert %{ok: true, error: nil} = data["good"]

      errors = for {id, %{ok: false, at: nil, error: error}} <- data, into: %{}, do: {id, error}

      assert errors == %{
               "v2" => "unknown factory_report version 2",
               "not-json" => "malformed JSON at byte 33",
               "broken" => "answered 500",
               "moved" => "answered 302",
               "guarded" => "answered 401",
               "missing" => "answered 404",
               "refused" => "connection refused",
               "slow" => "timed out"
             }

      # A failing node has no previous read; the good one has.
      assert state.nodes["good"].prev != nil
      assert state.nodes["v2"] == Reports.new_node()
    end

    test "the token is sent as a bearer token to every report URL", %{url: url, app: app} do
      targets = [{"open", url <> "/report"}, {"guarded", url <> "/guarded"}]

      {data, _} = collect!(Reports.init_state(targets: targets, token: "s3cret"))
      assert %{"open" => %{ok: true}, "guarded" => %{ok: true}} = data
      assert Agent.get(app, & &1.asked_with) == [["Bearer s3cret"]]

      {data, _} = collect!(Reports.init_state(targets: targets, token: "wrong"))
      assert %{"open" => %{ok: true}, "guarded" => %{ok: false, error: "answered 401"}} = data
    end

    test "a report that fails after a good read says when the good read was", %{
      url: url,
      app: app
    } do
      {data, state} = collect!(Reports.init_state(targets: [{"blog", url <> "/report"}]))
      at = data["blog"].at

      Agent.update(app, &%{&1 | body: "oops"})
      {data, _} = collect!(state)
      assert data["blog"] == %{ok: false, error: "malformed JSON at byte 0", at: at}
    end

    test "no report URLs: the round ran, with nothing in it" do
      assert {:ok, %{}, _} = Reports.collect(Reports.init_state(targets: []))
    end
  end

  test "it is the eighth source" do
    assert Reports.name() == :reports
    assert :reports in ObsFactor.Sources.names()
    assert length(ObsFactor.Sources.names()) == 8
  end
end
