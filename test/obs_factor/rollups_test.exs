defmodule ObsFactor.RollupsTest do
  @moduledoc """
  Hourly rollups against a real Postgres (OBJECTIVES_TEST_PG_URL or the
  local default). Frames are written straight into `tape_frames` at times
  of the test's choosing, hours in the past, so the job has completed
  hours to roll up; then the old frames are deleted, as `Tape.thin/2`
  would, and the writeup and the timeline's index must still say what
  happened.

  The seeded hours (H = the hour that started three hours ago):

    * H: a minute frame each minute; alerts 1 and a fire on "app" in the
      first 30, requests 10/s throughout, 5xx 0.5/s in the first 30; BEAM
      procs 100 then 200; 2 deploys and a crash on the wire
    * H+1: a fine frame every 5 s for 10 minutes at 100 req/s, then a minute
      frame each minute at 0 req/s: time-weighted, that is 16.67 req/s; a
      plain mean of the 170 frames would be 70.6
    * H+2: nothing (a gap)
    * a week before H: minute frames, alerts in the first 15
    * the current hour: a frame a second ago (the tape's live edge)
  """
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.{Objectives, Rollups, Tape}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")
  @hour 3_600_000
  @week 7 * 86_400_000

  setup_all do
    case ensure_database(@url) do
      :ok -> :ok
      {:error, why} -> {:skip, "no Postgres for rollup tests: #{why}"}
    end
  end

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS tape_rollups, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({Objectives, db: db})
    start_supervised!({Tape, db: db, topic: "rollups_test", thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)

    now = System.system_time(:millisecond)
    h = div(now, @hour) * @hour - 3 * @hour

    # H: one frame a minute, alerts in the first 30
    for i <- 0..59 do
      alert = i < 30
      frame(db, h + i * 60_000, alerts: if(alert, do: 1, else: 0), rps: 10.0, err: if(alert, do: 0.5, else: 0.0), procs: if(alert, do: 100, else: 200),
        fires: if(alert, do: [%{node: "app", severity: "alert", text: "App: 5xx"}], else: []))
    end

    # H+1: fine frames for 10 minutes at 100 req/s, then minute frames at 0
    for i <- 0..119, do: frame(db, h + @hour + i * 5_000, rps: 100.0, minute: rem(i, 12) == 0)
    for i <- 10..59, do: frame(db, h + @hour + i * 60_000, rps: 0.0)

    # a week before H: alerts in the first 15 minutes
    for i <- 0..59, do: frame(db, h - @week + i * 60_000, alerts: if(i < 15, do: 1, else: 0), rps: 5.0)

    # the live edge
    frame(db, now - 1_000, rps: 1.0)

    wire(db, h + 60_000, "deploy")
    wire(db, h + 120_000, "deploy")
    wire(db, h + 180_000, "crash")

    %{db: db, h: h, now: now}
  end

  test "an hour is rolled up from its frames: maxima, time-weighted means, alert seconds, wire by kind", %{h: h, db: db} do
    {:ok, r} = Rollups.compute(h, h + @hour, db)
    assert r.frames == 60
    # the last frame of H counts until the first of H+1: the hour is whole
    assert r.tape_s == 3600.0
    assert r.alerts_max == 1
    assert r.alert_s == 1800.0
    assert r.rps_mean == 10.0
    assert_in_delta r.err_rps_mean, 0.25, 1.0e-9
    assert r.err_rps_max == 0.5
    assert r.lanes == %{"app" => %{"alert_s" => 1800.0, "warn_s" => 0.0}}
    assert r.wire == %{"deploy" => 2, "crash" => 1}
    assert r.wire_apps == %{"app" => %{"deploy" => 2, "crash" => 1}}
    assert r.beam["beam:app@1"]["app"] == "app"
    assert r.beam["beam:app@1"]["procs"] == %{"mean" => 150.0, "max" => 200.0}
    assert r.dbs["pg:app_prod"] == %{"app" => "app", "conns" => %{"mean" => 5.0, "max" => 5.0}, "commits" => %{"mean" => 1.0, "max" => 1.0}}
    assert r.nodes["caddy"]["rps"] == %{"mean" => 10.0, "max" => 10.0}

    {:ok, r1} = Rollups.compute(h + @hour, h + 2 * @hour, db)
    assert r1.frames == 170
    # 600 s at 100, 3000 s at 0: not the 70.6 of a plain mean over frames
    assert_in_delta r1.rps_mean, 16.667, 0.001
    assert r1.rps_max == 100.0
  end

  test "the job rolls up each completed hour once, catches up from the start of the tape, and a re-roll replaces", %{h: h, now: now, db: db} do
    {:ok, pending} = Rollups.pending(now, 500, db)
    # the week-old hour, H and H+1; not the gap, not the hour in progress
    assert pending == [h - @week, h, h + @hour]

    {:ok, %{rolled: rolled, pruned: 0}} = Rollups.run(now, db)
    assert rolled == [h - @week, h, h + @hour]

    # again: nothing to do
    assert {:ok, %{rolled: [], pruned: 0}} = Rollups.run(now, db)

    {:ok, [before]} = Rollups.hours(h, h + @hour, db)
    {:ok, again} = Rollups.roll_hour(h, db)
    {:ok, [after_]} = Rollups.hours(h, h + @hour, db)
    assert again.alert_s == before.alert_s
    assert Map.delete(after_, :hour) == Map.delete(before, :hour)
    assert %{rows: [[3]]} = Postgrex.query!(db, "SELECT count(*) FROM tape_rollups", [])

    # an hour with no frame is not written
    assert {:ok, :empty} = Rollups.roll_hour(h + 2 * @hour, db)
  end

  test "the job catches up on start, by itself", %{db: db} do
    start_supervised!({Rollups, db: db, first_ms: 0, every_ms: 3_600_000})

    count = fn -> with {:ok, r} <- Postgrex.query(db, "SELECT count(*) FROM tape_rollups", []), do: r.rows end
    assert Enum.any?(1..40, fn _ -> count.() == [[3]] or (Process.sleep(50) && false) end)
  end

  test "rollups past 13 months are deleted", %{now: now, db: db} do
    old = div(now, @hour) * @hour - 400 * 86_400_000
    frame(db, old + 60_000, alerts: 1)
    {:ok, %{rolled: rolled, pruned: pruned}} = Rollups.run(now, db)
    assert old in rolled
    assert pruned == 1
    assert {:ok, []} = Rollups.hours(old, old + @hour, db)
  end

  describe "after the tape has thinned the old frames away" do
    setup %{db: db, now: now} do
      {:ok, _} = Rollups.run(now, db)
      Postgrex.query!(db, "DELETE FROM tape_frames WHERE at < $1", [DateTime.from_unix!(div(now, @hour) * @hour - @hour, :millisecond)])
      Postgrex.query!(db, "DELETE FROM tape_wire", [])
      :ok
    end

    test "summarize reads the kept hours, weighted by tape time", %{h: h, db: db} do
      {:ok, s} = Rollups.summarize(h, h + 2 * @hour, db)
      assert s.hours == 2
      assert s.frames == 230
      assert s.alert_s == 1800.0
      assert_in_delta s.rps_mean, (10.0 * 3600 + 16.667 * 3600) / 7200, 0.001
      assert s.wire["deploy"] == 2
      refute s.widened

      # an edge in the middle of an hour off the tape: the whole hour, said so
      {:ok, s} = Rollups.summarize(h + 30 * 60_000, h + @hour, db)
      assert s.hours == 1 and s.widened
    end

    test "the timeline's index has rollup columns before the tape, and says up to where", %{h: h, now: now, db: db} do
      {:ok, idx} = Rollups.index(h, now, 60, db)
      {:ok, start} = Rollups.tape_start(db)
      assert idx.rollups_to == start
      before = Enum.filter(idx.buckets, fn [t | _] -> t < start end)
      # H's columns carry its alert; H+2 (a gap) has none
      assert Enum.any?(before, fn [t, _n, a | _] -> t < h + @hour and a == 1 end)
      # an hour over several columns shares its frames out: not 60 in each
      inside = Enum.filter(before, fn [t | _] -> t >= h and t + idx.step <= h + @hour end)
      assert inside != [] and Enum.all?(inside, fn [_, n | _] -> n == round(60 * idx.step / @hour) end)
      refute Enum.any?(before, fn [t | _] -> t >= h + 2 * @hour + idx.step and t < h + 3 * @hour - idx.step end)
      # and the tape's own columns are still there
      assert Enum.any?(idx.buckets, fn [t | _] -> t >= start - idx.step end)

      # no rollup before the tape in the window: the tape's index, unchanged
      {:ok, idx} = Rollups.index(now - 60_000, now, 10, db)
      assert idx.rollups_to == nil
      assert {:ok, Map.delete(idx, :rollups_to)} == Tape.index(now - 60_000, now, 10, db)
    end
  end

  defp ensure_database(url) do
    uri = URI.parse(url)
    name = String.trim_leading(uri.path, "/")
    admin = %{uri | path: "/postgres"} |> URI.to_string()
    {:ok, pid} = Postgrex.start_link(ObsFactor.Postgres.opts(admin, name: nil, pool_size: 1, statement_timeout: "5000") |> Keyword.delete(:name) |> Keyword.put(:backoff_type, :stop))

    try do
      case Postgrex.query(pid, "SELECT 1 FROM pg_database WHERE datname = $1", [name]) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, _} -> Postgrex.query!(pid, ~s(CREATE DATABASE "#{name}"), []) && :ok
        {:error, e} -> {:error, Exception.message(e)}
      end
    catch
      :exit, reason -> {:error, inspect(reason)}
    after
      GenServer.stop(pid)
    end
  end

  # ---- seeding ----------------------------------------------------------------

  defp frame(db, at, o) do
    metrics = %{
      "caddy" => %{rps: o[:rps] || 0.0, err_rps: o[:err] || 0.0},
      "app" => %{rps: o[:rps] || 0.0, err_rps: o[:err] || 0.0, cpu_cores: 0.1},
      "beam:app@1" => %{app: "app", procs: o[:procs] || 100, mem: 100_000_000, reds: 5000.0, rq: 0, mbox: 0, mbox_name: "x"},
      "pg:app_prod" => %{app: "app", conns: 5, commits: 1.0}
    }

    body = :zlib.gzip(Jason.encode!(%{nodes: [%{id: "app", label: "App"}, %{id: "caddy", label: "Caddy"}]}))

    Postgrex.query!(db, """
    INSERT INTO tape_frames (at, body, minute_mark, alerts, warns, down, blocked, rps, err_rps, fires, metrics)
    VALUES ($1, $2, $3, $4, 0, 0, 0, $5, $6, $7, $8)
    """, [DateTime.from_unix!(at, :millisecond), body, Keyword.get(o, :minute, true), o[:alerts] || 0, o[:rps], o[:err] || 0.0, o[:fires] || [], metrics])
  end

  defp wire(db, at, kind) do
    Postgrex.query!(db, "INSERT INTO tape_wire (at, app, label, kind, sev, head) VALUES ($1, 'app', 'App', $2, 'info', $2)", [DateTime.from_unix!(at, :millisecond), kind])
  end
end
