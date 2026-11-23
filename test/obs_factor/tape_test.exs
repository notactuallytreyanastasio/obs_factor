defmodule ObsFactor.TapeTest do
  @moduledoc """
  The tape and the insights against a real Postgres, as
  ObsFactor.ObjectivesTest (OBJECTIVES_TEST_PG_URL or the local default).
  """
  use ExUnit.Case, async: false

  alias ObsFactor.{Insights, Objectives, Tape}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")
  @t0 1_790_000_000_000

  setup_all do
    case ensure_database(@url) do
      :ok -> :ok
      {:error, why} -> {:skip, "no Postgres for tape tests: #{why}"}
    end
  end

  setup do
    db = :"tape_test_db_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS tape_frames, objective_events, objectives", [])
    topic = "tape_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, topic)
    name = :"tape_#{System.unique_integer([:positive])}"
    start_supervised!({Tape, db: db, name: name, topic: topic, thin_first_ms: 3_600_000})
    %{db: db, tape: name}
  end

  defp snap(attention, opts \\ []) do
    %{
      at: "x",
      attention: attention,
      nodes: [
        %{id: "caddy", kind: "proxy", status: "working", hosts: [%{rps: opts[:rps] || 2.0, err_rps: opts[:err] || 0.0}]},
        %{id: "app", kind: "app", status: opts[:app] || "working", hosts: [%{rps: 99.0, err_rps: 99.0}]}
      ]
    }
  end

  defp alert(node, text), do: %{node: node, severity: "alert", text: text}

  # record and wait for the write (the broadcast follows the insert)
  defp put(tape, at, s) do
    json = Jason.encode!(s)
    Tape.record(at, json, Tape.summary(s), tape)
    assert_receive {:tape_frame, %{at: ^at}}, 2_000
  end

  test "a summary counts what the timeline draws and sums requests over the proxies only" do
    s = snap([alert("app", "down"), %{node: "db", severity: "warn", text: "slow"}, %{node: nil, severity: "info", text: "x"}], err: 0.5, app: "down")
    sum = Tape.summary(s)
    assert %{alerts: 1, warns: 1, down: 1, blocked: 0, rps: 2.0, err_rps: 0.5} = sum
    assert length(sum.fires) == 2
  end

  test "a frame comes back as it was recorded: the last at or before, or the first after", %{db: db, tape: tape} do
    put(tape, @t0, snap([]))
    put(tape, @t0 + 5_000, snap([alert("app", "on fire")]))

    assert {:ok, @t0, json, next} = Tape.frame(@t0 + 4_999, db)
    assert next == @t0 + 5_000
    assert Jason.decode!(json)["attention"] == []
    assert {:ok, at, json, nil} = Tape.frame(@t0 + 60_000, db)
    assert at == @t0 + 5_000
    assert [%{"text" => "on fire"}] = Jason.decode!(json)["attention"]
    assert {:ok, @t0, _, _} = Tape.frame(@t0 - 60_000, db)
    assert {:ok, %{from: @t0, to: ^at, frames: 2}} = Tape.range(db)
  end

  test "the index cuts a window into columns, worst of each, and leaves gaps out", %{db: db, tape: tape} do
    put(tape, @t0, snap([]))
    put(tape, @t0 + 5_000, snap([alert("app", "x")], err: 1.5))
    put(tape, @t0 + 50_000, snap([]))

    {:ok, %{step: 10_000, buckets: b}} = Tape.index(@t0, @t0 + 100_000, 10, db)
    assert [[@t0, 2, 1, 0, 0, 1.5, 2.0], [t, 1, 0, 0, 0, +0.0, 2.0]] = b
    assert t == @t0 + 50_000
  end

  test "burn: each frame counts until the next, a gap counts two minutes at most", %{db: db, tape: tape} do
    put(tape, @t0, snap([alert("app", "5xx")]))
    put(tape, @t0 + 5_000, snap([alert("app", "5xx again")]))
    put(tape, @t0 + 10_000, snap([]))
    put(tape, @t0 + 20_000, snap([alert("db", "connections")]))
    put(tape, @t0 + 3_600_000, snap([]))

    {:ok, burn} = Tape.burn(@t0, @t0 + 3_600_000, db)
    app = Enum.find(burn, &(&1.node == "app"))
    assert app.ms == 10_000 and app.text == "5xx again" and app.severity == "alert"
    assert Enum.find(burn, &(&1.node == "db")).ms == 120_000
  end

  test "weather: the calm share, the last alert, one peak per minute", %{db: db, tape: tape} do
    put(tape, @t0, snap([], err: 0.2))
    put(tape, @t0 + 5_000, snap([alert("app", "x")], err: 3.0))
    put(tape, @t0 + 10_000, snap([], err: 2.0))
    put(tape, @t0 + 20_000, snap([]))

    {:ok, w} = Tape.weather(@t0, @t0 + 20_000, db)
    assert w.frames == 4 and w.tape_ms == 20_000 and w.calm_ms == 15_000
    assert w.last_alert == @t0 + 5_000
    assert [%{at: at, err_rps: 3.0}] = w.peaks
    assert at == @t0 + 5_000
    assert %{alerts: 1} = w.worst
  end

  test "thinning keeps every tick while fine, then the first of each minute, then nothing", %{db: db, tape: tape} do
    for i <- 0..23, do: put(tape, @t0 + i * 5_000, snap([]))
    count = fn -> Postgrex.query!(db, "SELECT count(*) FROM tape_frames", []).rows |> hd() |> hd() end
    assert count.() == 24

    state = %{db: db, fine_ms: 60_000, keep_ms: 10 * 86_400_000, logged_at: 0}
    Tape.thin(state, @t0 + 10 * 60_000)
    # 24 ticks from @t0 over 115 s touch three minutes: one mark in each
    assert count.() == 3
    Tape.thin(%{state | keep_ms: 60_000}, @t0 + 10 * 60_000)
    assert count.() == 0
  end

  test "insights: put out, burned out with nobody coming, how fast, and the hot spots", %{db: db, tape: tape} do
    obj = :"obj_#{System.unique_integer([:positive])}"
    start_supervised!({Objectives, db: db, name: obj, topic: "objtape_#{System.unique_integer([:positive])}"})
    Process.sleep(200)
    now = System.system_time(:millisecond)
    Objectives.observe([alert("app", "app 5xx"), alert("db", "db slow")], %{}, obj)
    {:ok, list} = Objectives.list(obj)
    app = Enum.find(list, &(&1.node == "app"))
    {:ok, _} = Objectives.act(app.id, "look", %{"by" => "bg"}, obj)
    {:ok, _} = Objectives.act(app.id, "done", %{"by" => "bg", "note" => "restarted"}, obj)
    # the db one goes away by itself
    GenServer.cast(obj, {:observe, [], %{}, now + 61_000})
    {:ok, _} = Objectives.list(obj)

    # the tape is in the past, as it always is: its last frame runs to now
    put(tape, now - 30_000, snap([alert("app", "app 5xx"), alert("db", "db slow")], err: 1.0))
    put(tape, now - 25_000, snap([alert("app", "app 5xx")], err: 0.5))
    put(tape, now - 20_000, snap([]))

    {:ok, i} = Insights.compute(now - 31_000, now + 120_000, db)
    assert %{started: 2, put_out: 1, burned_out: 1, unattended: 1, burning: 0} = i.score
    # a window that ends after app was crossed off but before db cleared
    # itself (at now + 61 s): db was still burning then
    {:ok, early} = Insights.compute(now - 31_000, now + 30_000, db)
    assert early.score.burning == 1
    assert is_integer(i.score.respond_ms) and is_integer(i.score.put_out_ms)
    assert [%{node: "app", alert_ms: 10_000, fires: 1}, %{node: "db", alert_ms: 5_000}] = i.hot
    assert i.calm.share > 0 and i.calm.share < 1
    assert [%{err_rps: 1.0} | _] = i.peaks
  end

  defp ensure_database(url) do
    uri = URI.parse(url)
    db = String.trim_leading(uri.path, "/")
    admin = %{uri | path: "/postgres"} |> URI.to_string()
    {:ok, pid} = Postgrex.start_link(ObsFactor.Postgres.opts(admin, name: nil, pool_size: 1, statement_timeout: "5000") |> Keyword.delete(:name) |> Keyword.put(:backoff_type, :stop))

    try do
      case Postgrex.query(pid, "SELECT 1 FROM pg_database WHERE datname = $1", [db]) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, _} -> Postgrex.query!(pid, ~s(CREATE DATABASE "#{db}"), []) && :ok
        {:error, e} -> {:error, Exception.message(e)}
      end
    catch
      :exit, reason -> {:error, inspect(reason)}
    after
      GenServer.stop(pid)
    end
  end
end
