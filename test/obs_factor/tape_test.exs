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
    Postgrex.query!(db, "DROP TABLE IF EXISTS tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    topic = "tape_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, topic)
    name = :"tape_#{System.unique_integer([:positive])}"
    start_supervised!({Tape, db: db, name: name, topic: topic, thin_first_ms: 3_600_000})
    # the schema is made in handle_continue: a call after it has run
    _ = :sys.get_state(name)
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
  defp warn(node, text), do: %{node: node, severity: "warn", text: text}

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

  test "the board keeps a few numbers per node, rounded, and drops what is unknown" do
    m = %{"caddy" => %{rps: 12.345678, err_rps: 0.0, p95_ms: nil, units: 9}, "db" => %{commits_per_s: 2.61234, connections: 91}, "x" => %{rps: nil}}
    assert Tape.board(m) == %{"caddy" => %{rps: 12.35, err_rps: 0}, "db" => %{commits_per_s: 2.612, connections: 91}}
  end

  test "series: every k-th frame of the window, newest always in, with its numbers", %{db: db, tape: tape} do
    for i <- 0..9 do
      s = snap([])
      Tape.record(@t0 + i * 5_000, Jason.encode!(s), Tape.summary(s, %{"caddy" => %{rps: i * 1.0}}), tape)
      assert_receive {:tape_frame, %{metrics: %{"caddy" => %{rps: _}}}}, 2_000
    end

    {:ok, all} = Tape.series(@t0, @t0 + 60_000, 100, db)
    assert length(all) == 10
    assert [[@t0, %{"caddy" => %{"rps" => 0}}] | _] = all
    {:ok, some} = Tape.series(@t0, @t0 + 60_000, 4, db)
    assert length(some) <= 4 and List.last(some) == List.last(all)
  end

  test "lanes: each building's runs, a gap over 90 s ends one, alert and warning apart", %{db: db, tape: tape} do
    put(tape, @t0, snap([alert("app", "5xx 1"), warn("db", "slow")]))
    put(tape, @t0 + 5_000, snap([alert("app", "5xx 2")]))
    put(tape, @t0 + 60_000, snap([]))
    put(tape, @t0 + 200_000, snap([alert("app", "5xx 3")]))

    {:ok, lanes} = Tape.lanes(@t0, @t0 + 300_000, db)
    assert [
             ["app", "alert", @t0, a_end, 2, "5xx 2"],
             ["db", "warn", @t0, @t0, 1, "slow"],
             ["app", "alert", b, b, 1, "5xx 3"]
           ] = Enum.sort_by(lanes, &{Enum.at(&1, 2), Enum.at(&1, 0) == "db"})
    assert a_end == @t0 + 5_000 and b == @t0 + 200_000
  end

  test "windows: saved, trimmed, renamed, pruned; bad edges refused", %{db: db, tape: tape} do
    put(tape, @t0 + 5_000, snap([]))
    {:ok, w} = Tape.save_window(%{"from" => @t0, "to" => @t0 + 10_000, "title" => "  links down  ", "by" => "bg"}, db)
    assert %{title: "links down", by: "bg", frames: 1, from: @t0} = w
    {:ok, w2} = Tape.save_window(%{"id" => w.id, "from" => @t0 + 6_000, "to" => @t0 + 10_000, "title" => "trimmed"}, db)
    assert %{id: id, from: f, frames: 0, title: "trimmed", by: "bg"} = w2
    assert id == w.id and f == @t0 + 6_000
    assert {:ok, [%{id: ^id}]} = Tape.windows(db)
    assert {:error, "a window is" <> _} = Tape.save_window(%{"from" => @t0, "to" => @t0}, db)
    assert {:error, "no window" <> _} = Tape.save_window(%{"id" => -1, "from" => @t0, "to" => @t0 + 1}, db)
    assert {:ok, [^id]} = Tape.prune_windows([id], db)
    # pruned, listed for an hour so it can be restored
    assert {:ok, [%{id: ^id, pruned_at: p}]} = Tape.windows(db)
    assert is_integer(p)
    assert {:error, "no window" <> _} = Tape.save_window(%{"id" => id, "from" => @t0, "to" => @t0 + 1_000}, db)
    assert {:ok, [^id]} = Tape.restore_windows([id], db)
    assert {:ok, [%{pruned_at: nil}]} = Tape.windows(db)
    # an hour on, a prune is final: not listed, cannot be restored
    {:ok, _} = Tape.prune_windows([id], db)
    Postgrex.query!(db, "UPDATE tape_windows SET pruned_at = now() - interval '61 minutes'", [])
    assert {:ok, []} = Tape.windows(db)
    assert {:ok, []} = Tape.restore_windows([id], db)
  end

  test "a note sent replaces the note, even empty; none sent keeps it", %{db: db} do
    {:ok, w} = Tape.save_window(%{"from" => @t0, "to" => @t0 + 10_000, "note" => "first"}, db)
    {:ok, w} = Tape.save_window(%{"id" => w.id, "from" => @t0, "to" => @t0 + 10_000, "title" => "t"}, db)
    assert w.note == "first"
    {:ok, w} = Tape.save_window(%{"id" => w.id, "from" => @t0, "to" => @t0 + 10_000, "title" => "t", "note" => "  "}, db)
    assert w.note == nil
  end

  test "thinning leaves every frame inside a saved window", %{db: db, tape: tape} do
    for i <- 0..23, do: put(tape, @t0 + i * 5_000, snap([]))
    {:ok, _} = Tape.save_window(%{"from" => @t0 + 50_000, "to" => @t0 + 70_000}, db)
    count = fn -> Postgrex.query!(db, "SELECT count(*) FROM tape_frames", []).rows |> hd() |> hd() end
    Tape.thin(%{db: db, fine_ms: 60_000, keep_ms: 60_000, logged_at: 0}, @t0 + 10 * 60_000)
    # everything is past keep: only the 5 frames in the window are left
    assert count.() == 5
    # pruned a minute ago: still spared, it can be undone
    {:ok, [w]} = Tape.windows(db)
    {:ok, _} = Tape.prune_windows([w.id], db)
    Tape.thin(%{db: db, fine_ms: 60_000, keep_ms: 60_000, logged_at: 0}, @t0 + 10 * 60_000)
    assert count.() == 5
    # pruned over an hour ago: the window goes on this pass, its frames on the next
    Postgrex.query!(db, "UPDATE tape_windows SET pruned_at = now() - interval '61 minutes'", [])
    Tape.thin(%{db: db, fine_ms: 60_000, keep_ms: 60_000, logged_at: 0}, @t0 + 10 * 60_000)
    Tape.thin(%{db: db, fine_ms: 60_000, keep_ms: 60_000, logged_at: 0}, @t0 + 10 * 60_000)
    assert count.() == 0
  end

  test "the wire rides on the frame: written with it, pushed on the tick, read back newest first", %{db: db, tape: tape} do
    i = fn at, head -> %{at: at, app: "marginalia", label: "Marginalia", member: "marginalia@172.18.0.10", kind: "restart", sev: "warn", head: head, text: "up 4h"} end
    s = snap([])
    Tape.record(@t0, Jason.encode!(s), Tape.summary(s, %{}, %{"beam:m@1" => %{procs: 5}}, [i.(@t0, "one"), i.(@t0, "two")]), tape)
    assert_receive {:tape_frame, %{wire: [%{head: "one"}, %{head: "two"}], metrics: %{"beam:m@1" => %{procs: 5}}}}, 2_000
    {:ok, w} = Tape.wire(@t0 - 1, @t0 + 1, 500, db)
    assert [%{head: _, app: "marginalia", sev: "warn", at: @t0}, _] = w
    assert w |> Enum.map(& &1.head) |> Enum.sort() == ["one", "two"]
    assert {:ok, [_, _]} = Tape.wire(@t0 - 1, @t0 + 1, 500, db, ["restart"])
    assert {:ok, []} = Tape.wire(@t0 - 1, @t0 + 1, 500, db, ["deploy"])
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
