defmodule ObsFactor.HeartbeatTest do
  # The heartbeat pings only while ObsFactor.Health says the observer is
  # observing. A fake poster sends every request here instead of the network;
  # the last test sends real HTTP to a Bandit on a free port.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias ObsFactor.{Health, Heartbeat}

  doctest Heartbeat

  @url "https://hc-ping.com/1f2e3d"

  defp start(check, opts \\ []) do
    me = self()

    post = fn method, url, body ->
      send(me, {:posted, method, url, body})
      Keyword.get(opts, :answer, :ok)
    end

    name = :"hb_#{System.unique_integer([:positive])}"

    base = [url: @url, name: name, check: check, first_after_ms: 60_000, interval_ms: 60_000]
    base = if opts[:real_http], do: base, else: [{:post, post} | base]
    start_supervised!({Heartbeat, Keyword.merge(base, opts)}, id: name)
  end

  defp health(opts), do: fn -> Health.check(opts) end

  @fresh [
    now: 100_000,
    snapshot_at: 97_000,
    ticker_alive: true,
    snapshot: {:ok, "{}"},
    sources: %{docker: %{ok: true}, caddy: %{ok: true}, host: %{ok: false}},
    max_age_ms: 30_000
  ]

  test "healthy: POSTs the url with one line saying how fresh" do
    hb = start(health(@fresh))
    assert {:pinged, :ok} = Heartbeat.beat(hb)
    assert_received {:posted, :post, @url, "ok snapshot_age=3s sources=2/3"}
  end

  test "stale: no ping at all, so the checker alarms when its grace runs out" do
    hb = start(health(Keyword.put(@fresh, :snapshot_at, 60_000)))
    assert {:skipped, "snapshot_stale"} = Heartbeat.beat(hb)
    refute_received {:posted, _, _, _}
  end

  test "a wedged ticker (alive, no new snapshot) stops the pings like a dead one" do
    hb = start(health(Keyword.merge(@fresh, snapshot_at: 0, snapshot: {:ok, "{}"})))
    assert {:skipped, "snapshot_stale"} = Heartbeat.beat(hb)

    hb = start(health(Keyword.put(@fresh, :ticker_alive, false)))
    assert {:skipped, "ticker_down"} = Heartbeat.beat(hb)
    refute_received {:posted, _, _, _}
  end

  test "with fail: true an unhealthy check POSTs <url>/fail instead" do
    hb =
      start(health(Keyword.merge(@fresh, snapshot_at: 1_000, snapshot: {:error, "boom"})),
        fail: true
      )

    assert {:failed, :ok} = Heartbeat.beat(hb)

    assert_received {:posted, :post, "https://hc-ping.com/1f2e3d/fail",
                     "fail snapshot_failing snapshot_age=99s sources=2/3"}
  end

  test "method: :get sends a GET (Uptime Kuma push URLs)" do
    hb =
      start(health(@fresh),
        method: :get,
        url: "https://kuma.example/api/push/tok?status=up&msg=OK"
      )

    assert {:pinged, :ok} = Heartbeat.beat(hb)
    assert_received {:posted, :get, "https://kuma.example/api/push/tok?status=up&msg=OK", _}
  end

  test "a check that raises is reported, not a crash that takes the app down" do
    hb = start(fn -> raise "no ets" end)
    assert {:error, "no ets"} = Heartbeat.beat(hb)
    assert Process.alive?(hb)
  end

  test "an undelivered ping is an error result, and the next beat tries again" do
    hb = start(health(@fresh), answer: {:error, "answered 500"})
    assert {:pinged, {:error, "answered 500"}} = Heartbeat.beat(hb)
    assert {:pinged, {:error, "answered 500"}} = Heartbeat.beat(hb)
  end

  test "the timer beats on its own" do
    start(health(@fresh), first_after_ms: 1, interval_ms: 20)
    assert_receive {:posted, :post, @url, _}, 500
    assert_receive {:posted, :post, @url, _}, 500
  end

  test "fail_url keeps the query and does not double a slash" do
    assert Heartbeat.fail_url("https://hc-ping.com/abc/") == "https://hc-ping.com/abc/fail"

    assert Heartbeat.fail_url("https://up.example/push/x?status=up") ==
             "https://up.example/push/x/fail?status=up"
  end

  test "configured_child is nil without HEARTBEAT_URL" do
    assert Heartbeat.configured_child() == nil
  end

  defmodule Catcher do
    @behaviour Plug
    def init(to), do: to

    def call(conn, to) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(to, {:hit, conn.method, conn.request_path, body})
      Plug.Conn.send_resp(conn, 200, "OK")
    end
  end

  test "the default poster sends real HTTP and reads the status" do
    {:ok, server} =
      Bandit.start_link(plug: {Catcher, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    hb = start(health(@fresh), url: "http://127.0.0.1:#{port}/ping/abc", real_http: true)
    assert {:pinged, :ok} = Heartbeat.beat(hb)
    assert_received {:hit, "POST", "/ping/abc", "ok snapshot_age=3s sources=2/3"}
  end
end
