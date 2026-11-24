defmodule ObsFactorWeb.StructuredLogTest do
  # The JSON lines prod writes (config :obs_factor, :log_formatter, the
  # formatter prod's default handler uses) and the metadata of the events
  # that matter for aggregation. A :logger handler of its own formats every
  # event with that formatter and sends the decoded line here.
  use ObsFactorWeb.ConnCase, async: false
  import Phoenix.ChannelTest, except: [connect: 2, connect: 3]
  require Phoenix.ChannelTest

  alias ObsFactor.ObserverProxy

  @endpoint ObsFactorWeb.Endpoint
  @moduletag :capture_log
  @handler :structured_log_test

  # ---- the :logger handler ------------------------------------------------

  @doc false
  def log(event, %{config: %{to: to}, formatter: {mod, cfg}}) do
    send(to, {:json, event.meta[:pid], IO.iodata_to_binary(mod.format(event, cfg))})
  end

  setup do
    :ok =
      :logger.add_handler(@handler, __MODULE__, %{
        level: :all,
        config: %{to: self()},
        formatter: Application.fetch_env!(:obs_factor, :log_formatter)
      })

    on_exit(fn -> :logger.remove_handler(@handler) end)
    :ok
  end

  # The next line with this `event` (and, with `pid`, logged by that
  # process: other tests make requests meanwhile), decoded, and raw.
  defp line(event, pid \\ nil) do
    receive do
      {:json, from, raw} ->
        json = Jason.decode!(raw)
        if json["event"] == event and pid in [nil, from], do: {json, raw}, else: line(event, pid)
    after
      2_000 -> flunk("no #{event} line logged")
    end
  end

  test "a line is one JSON object in factory_report's shape, with the fields after it" do
    Logger.put_module_level(ObsFactorWeb.Log, :debug)
    # no ticker runs in test, so /health answers 503 (ObsFactor.Health)
    conn = get(build_conn(), "/health")
    assert conn.status == 503

    {json, raw} = line("http.request", self())
    assert String.ends_with?(raw, "}\n") and not String.contains?(String.trim_trailing(raw), "\n")

    # factory_report's keys first, in its order (FactoryReport.JSONFormatter)
    assert Enum.take(Jason.decode!(raw, objects: :ordered_objects).values |> Enum.map(&elem(&1, 0)), 7) ==
             ~w(time level msg app module request_id page)

    assert %{"level" => "info", "app" => "obs_factor", "module" => "ObsFactorWeb.Log", "event" => "http.request"} = json
    assert {:ok, _, 0} = DateTime.from_iso8601(json["time"])
    assert json["request_id"] == conn |> Plug.Conn.get_resp_header("x-request-id") |> hd()
    assert %{"method" => "GET", "path" => "/health", "route" => "/health", "status" => 503} = json
    assert is_number(json["took_ms"]) and json["took_ms"] >= 0
    assert json["msg"] =~ ~r{^GET /health 503 in [\d.]+ ms$}
  after
    Logger.delete_module_level(ObsFactorWeb.Log)
  end

  test "an endpoint with log: false (/api/logs) writes no request line" do
    Logger.put_module_level(ObsFactorWeb.Log, :debug)
    get(build_conn(), "/api/logs")
    get(build_conn(), "/health")
    {json, _} = line("http.request", self())
    assert json["path"] == "/health"
  after
    Logger.delete_module_level(ObsFactorWeb.Log)
  end

  test "an exception rendered as an error page is http.error_rendered, at the endpoint's level" do
    meta = %{conn: build_conn(:get, "/boom"), status: 500, kind: :error, reason: %RuntimeError{message: "boom"}, stacktrace: [], log: :warning}
    ObsFactorWeb.Log.handle_event([:phoenix, :error_rendered], %{duration: 1}, meta, nil)
    {json, _} = line("http.error_rendered", self())

    assert %{"level" => "warning", "method" => "GET", "path" => "/boom", "status" => 500, "kind" => "error", "reason" => "RuntimeError"} = json
    assert json["msg"] == "converted error RuntimeError to a 500 response"
  end

  test "a connect and a join, as socket.connected and channel.joined" do
    Logger.put_module_level(ObsFactorWeb.Log, :debug)
    assert {:ok, socket} = Phoenix.ChannelTest.connect(ObsFactorWeb.UserSocket, %{"token" => ObsFactorWeb.UserSocket.token("t")})
    {connected, _} = line("socket.connected", self())
    assert %{"level" => "info", "transport" => "Phoenix.ChannelTest"} = connected
    refute Map.has_key?(connected, "reason")

    {:ok, _, _} = subscribe_and_join(socket, "actions")
    {joined, _} = line("channel.joined")
    assert %{"level" => "info", "topic" => "actions", "channel" => "ObsFactorWeb.ActionsChannel"} = joined
    assert is_number(joined["took_ms"])
  after
    Logger.delete_module_level(ObsFactorWeb.Log)
  end

  test "a refused socket says why, as socket.refused" do
    assert {:error, :invalid} = Phoenix.ChannelTest.connect(ObsFactorWeb.UserSocket, %{"token" => "nope"})
    {json, _} = line("socket.refused")
    assert %{"level" => "warning", "reason" => "token invalid", "transport" => "Phoenix.ChannelTest"} = json
    assert is_number(json["took_ms"])
    # the reason does not stick to the process's later lines
    assert Logger.metadata()[:reason] == nil
  end

  test "a refused join says which topic and why, as channel.refused" do
    socket = socket(ObsFactorWeb.UserSocket, "session:t", %{sid: "t"})
    assert {:error, %{reason: reason}} = subscribe_and_join(socket, ObsFactorWeb.FeedChannel, "observer:nope:-:system")
    {json, _} = line("channel.refused")

    assert %{"topic" => "observer:nope:-:system", "channel" => "ObsFactorWeb.FeedChannel", "reason" => ^reason} = json
    assert reason =~ "nope"
  end

  describe "observer actions" do
    setup do
      Application.put_env(:obs_factor, :observer_actions_token, "structured-log-test")
      on_exit(fn -> Application.delete_env(:obs_factor, :observer_actions_token) end)
    end

    test "done: who, what, on what, the result and how long, as action.done" do
      victim = spawn(fn -> Process.sleep(:infinity) end)
      pid = victim |> :erlang.pid_to_list() |> to_string() |> String.trim("<") |> String.trim(">")

      assert {200, _} = ObserverProxy.call("POST", "observer", ["proc", pid, "gc"], %{}, by: "dana (test)")
      {json, _} = line("action.done")

      assert %{
               "level" => "warning",
               "source" => "actions",
               "node" => "observer",
               "member" => nil,
               "action" => "gc",
               "target" => ^pid,
               "path" => "proc/" <> _,
               "by" => "dana (test)",
               "status" => 200,
               "error" => nil
             } = json

      assert is_number(json["took_ms"])
      Process.exit(victim, :kill)

      # the log explorer's facets are the same metadata (nil left out)
      ring = ObsFactor.LogRing.recent(2000, :warning) |> Enum.filter(&(&1.attrs[:event] == "action.done")) |> List.last()
      assert %{node: "observer", action: "gc", by: "dana (test)", status: 200} = ring.attrs
      refute Map.has_key?(ring.attrs, :member)
    end

    test "refused: the status and the error, by nil when nobody said, as action.refused" do
      assert {400, _} = ObserverProxy.call("POST", "observer", ["proc", "0.1.0", "exit"], %{"reason" => "normal"}, [])
      {json, _} = line("action.refused")

      assert %{
               "action" => "exit",
               "target" => "0.1.0",
               "args" => ~s(reason="normal"),
               "by" => nil,
               "status" => 400,
               "error" => "say who is acting: an x-factory-by header or \"by\" in the body"
             } = json
    end
  end

  describe "collector sources" do
    defmodule Flaky do
      @behaviour ObsFactor.Collector
      def name, do: :builder
      def init_state(opts), do: Keyword.fetch!(opts, :script)
      def collect([{:error, msg} | rest]), do: {:error, msg, rest}
      def collect([:ok | rest]), do: {:ok, %{}, rest}
      def collect([]), do: {:ok, %{}, []}
    end

    test "source.failed with the reason, then source.recovered with what had failed" do
      Logger.put_module_level(ObsFactor.Collector, :debug)

      {:ok, pid} =
        ObsFactor.Collector.start_link(Flaky, interval_ms: 30, deadline_ms: 20, script: [{:error, "host not found"}, :ok])

      on_exit(fn ->
        Logger.delete_module_level(ObsFactor.Collector)
        :ets.delete(ObsFactor.Sources, :builder)
      end)

      {failed, _} = line("source.failed")
      assert %{"level" => "warning", "source" => "builder", "reason" => "host not found", "module" => "ObsFactor.Collector"} = failed
      assert is_integer(failed["took_ms"])

      {recovered, _} = line("source.recovered")
      assert %{"level" => "info", "source" => "builder", "previous_error" => "host not found"} = recovered
      GenServer.stop(pid)
    end
  end
end
