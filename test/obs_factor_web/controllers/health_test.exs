defmodule ObsFactorWeb.HealthTest do
  # GET /health as the watchdog and the deploy check read it: the status
  # says ok or not, the body why, and nothing inside the box is named.
  # Shares the application's Store and registers ObsFactor.Ticker.
  use ObsFactorWeb.ConnCase, async: false

  alias ObsFactor.Store

  setup do
    ticker = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(ticker, ObsFactor.Ticker)

    on_exit(fn ->
      Process.exit(ticker, :kill)
      Store.clear_snapshot()
    end)

    {:ok, ticker: ticker}
  end

  test "200 with the snapshot age when the last snapshot is fresh", %{conn: conn} do
    Store.put_snapshot({:ok, ~s({"nodes":[]})})
    conn = get(conn, "/health")
    body = json_response(conn, 200)

    assert body["ok"] == true
    assert body["snapshot_age_s"] in [0, 1]
    assert Map.keys(body) |> Enum.sort() == ~w(ok snapshot_age_s sources_ok sources_total)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "503 snapshot_stale when the last good snapshot is older than the limit", %{conn: conn} do
    Store.put_snapshot({:ok, "{}"})
    Application.put_env(:obs_factor, :health_max_age_ms, 0)
    on_exit(fn -> Application.delete_env(:obs_factor, :health_max_age_ms) end)
    Process.sleep(5)

    assert %{"ok" => false, "reason" => "snapshot_stale"} =
             conn |> get("/health") |> json_response(503)
  end

  test "503 snapshot_failing names no error message", %{conn: conn} do
    Store.put_snapshot({:ok, "{}"})
    Store.put_snapshot({:error, "secret internal path /opt/blog exploded"})
    Application.put_env(:obs_factor, :health_max_age_ms, 0)
    on_exit(fn -> Application.delete_env(:obs_factor, :health_max_age_ms) end)
    Process.sleep(5)

    conn = get(conn, "/health")
    assert %{"ok" => false, "reason" => "snapshot_failing"} = json_response(conn, 503)
    refute conn.resp_body =~ "opt"
  end

  test "503 no_snapshot_yet before the first tick", %{conn: conn} do
    Store.clear_snapshot()

    assert %{"ok" => false, "reason" => "no_snapshot_yet", "snapshot_age_s" => nil} =
             conn |> get("/health") |> json_response(503)
  end

  test "503 ticker_down with a fresh snapshot but no ticker", %{conn: conn, ticker: ticker} do
    Store.put_snapshot({:ok, "{}"})
    Process.unregister(ObsFactor.Ticker)
    Process.exit(ticker, :kill)

    assert %{"ok" => false, "reason" => "ticker_down"} =
             conn |> get("/health") |> json_response(503)
  end
end
