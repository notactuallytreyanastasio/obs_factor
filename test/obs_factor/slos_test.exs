defmodule ObsFactor.SLOsTest do
  @moduledoc """
  Error budgets against a real Postgres (OBJECTIVES_TEST_PG_URL or the
  local default): tape frames are seeded straight into `tape_frames`, one a
  minute, with the per-node `metrics` the ticker writes, and the SLIs,
  budgets, burn rates and flags are read back off them.
  """
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.{SLOs, Tape}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")
  @min 60_000
  @hour 3_600_000

  setup_all do
    case ensure_database(@url) do
      :ok -> :ok
      {:error, why} -> {:skip, "no Postgres for SLO tests: #{why}"}
    end
  end

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS slo_targets, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({ObsFactor.Objectives, db: db})
    topic = "slo_tape_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, topic)
    start_supervised!({Tape, db: db, topic: topic, thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)
    _ = SLOs.drain()
    # minute-aligned, so every seeded frame stands for exactly 60 s
    now = div(System.system_time(:millisecond), @min) * @min
    %{db: db, now: now, tape_topic: topic}
  end

  # one frame a minute over [from, to), `metrics` a SQL jsonb expression of
  # the frame's time `at`
  defp seed(db, from_ms, to_ms, metrics) do
    Postgrex.query!(db, """
    INSERT INTO tape_frames (at, body, minute_mark, alerts, warns, down, blocked, rps, err_rps, fires, metrics)
    SELECT at, $3::bytea, true, 0, 0, 0, 0, NULL, NULL, '[]'::jsonb, #{metrics}
    FROM generate_series($1::timestamptz, $2::timestamptz - interval '1 minute', interval '1 minute') AS at
    ON CONFLICT (at) DO NOTHING
    """, [DateTime.from_unix!(from_ms, :millisecond), DateTime.from_unix!(to_ms, :millisecond), :zlib.gzip(~s({"nodes":[]}))])
  end

  # "shop": 10 req/s for two days, 0.1 % 5xx, then 12 % 5xx for the last hour
  defp seed_shop(db, now) do
    seed(db, now - 48 * @hour, now, """
    jsonb_build_object('shop', jsonb_build_object('rps', 10, 'err_rps', CASE WHEN at >= $2::timestamptz - interval '1 hour' THEN 1.2 ELSE 0.01 END,
                                                  'p95_ms', CASE WHEN at >= $2::timestamptz - interval '30 minutes' THEN 900 ELSE 120 END),
                       'blog', jsonb_build_object('rps', 2),
                       'caddy', jsonb_build_object('rps', 12, 'err_rps', 0))
    """)
  end

  test "the thresholds are the workbook's budget shares, scaled to the window" do
    assert SLOs.thresholds(30) == %{fast: 14.4, slow: 6.0}
    assert SLOs.thresholds(7) == %{fast: 3.36, slow: 1.4}
  end

  test "targets are checked, replaced per node, listed and deleted", %{db: db} do
    assert {:ok, %{node: "shop", availability: 0.995, window_days: 30, latency_ms: nil}} = SLOs.save(%{"node" => " shop ", "availability" => 0.995}, db)
    assert {:ok, %{window_days: 7, latency_ms: 250.0, latency_target: 0.99}} = SLOs.save(%{"node" => "shop", "availability" => 0.99, "window_days" => 7, "latency_ms" => 250}, db)
    assert {:ok, [%{node: "shop", availability: 0.99}]} = SLOs.targets(db)
    assert {:error, "availability is a share between 0.5 and 1" <> _} = SLOs.save(%{"node" => "x", "availability" => 1}, db)
    assert {:error, "window_days is 7 or 30" <> _} = SLOs.save(%{"node" => "x", "availability" => 0.9, "window_days" => 14}, db)
    assert {:error, "a target needs a node id"} = SLOs.save(%{"availability" => 0.9}, db)
    assert {:error, "latency_ms is" <> _} = SLOs.save(%{"node" => "x", "availability" => 0.9, "latency_ms" => -1}, db)
    assert {:ok, "shop"} = SLOs.delete("shop", db)
    assert {:error, "no target for shop"} = SLOs.delete("shop", db)
  end

  test "SLI, budget, burn over 1 h and 6 h, fast flag, and a 30-day window on a 2-day tape", %{db: db, now: now} do
    seed_shop(db, now)
    {:ok, _} = SLOs.save(%{"node" => "shop", "availability" => 0.995, "window_days" => 30, "latency_ms" => 500, "latency_target" => 0.95}, db)
    {:ok, _} = SLOs.save(%{"node" => "blog", "availability" => 0.99, "window_days" => 7}, db)

    {:ok, [blog, shop]} = SLOs.report(now, db: db, labels: %{"shop" => "Shop"})

    # 47 h at 0.1 % and 1 h at 12 %: 0.347917 % of requests failed
    a = shop.availability
    assert a.requests == 10 * 48 * 3600
    assert_in_delta a.sli, 1 - 0.167 / 48, 1.0e-9
    # 1 - 0.00347917 / 0.005 = 30.42 %
    assert a.budget_left_pct == 30.4
    # 12 % over the last hour on a 0.5 % budget: 24x, as over the last 5 m
    assert a.burn["1h"] == 24.0 and a.burn["5m"] == 24.0
    # 6 h: (5 h * 0.1 % + 1 h * 12 %) / 6 h = 2.08 %, 4.17x: under 6x
    assert a.burn["6h"] == 4.167
    assert a.fast and not a.slow
    assert shop.label == "Shop"
    assert shop.coverage.note =~ "a 30-day window, but the tape keeps 7 days and begins 2d 0h ago"
    assert shop.coverage.covered_ms == 48 * @hour

    # latency: the last 30 minutes had p95 900 ms against 500: 30 of 2880 minutes
    l = shop.latency
    assert_in_delta l.sli, 1 - 30 / 2880, 1.0e-9
    # 30 m all slow on a 5 % budget: 20x over 30 m and 5 m, but 10x over
    # 1 h (under 14.4x) and 1.67x over 6 h (under 6x): no flag. The short
    # windows confirm; they never flag alone
    assert l.burn["30m"] == 20.0 and l.burn["5m"] == 20.0 and l.burn["1h"] == 10.0 and l.burn["6h"] == 1.667
    refute l.fast or l.slow

    # blog is reached only by path routes: requests, no 5xx count
    assert blog.availability.sli == nil
    assert blog.note =~ "reached only by path routes"
    assert blog.coverage.note =~ "the tape begins 2d 0h ago"
  end

  test "a slow burn on a 7-day window flags at 1.4x, and too few requests flag nothing", %{db: db, now: now} do
    # 2 % 5xx for 6 hours on a 1 % budget: 2x, over 7 days' 1.4x but under 3.36x
    seed(db, now - 24 * @hour, now, "jsonb_build_object('api', jsonb_build_object('rps', 5, 'err_rps', CASE WHEN at >= $2::timestamptz - interval '6 hours' THEN 0.1 ELSE 0 END))")
    {:ok, _} = SLOs.save(%{"node" => "api", "availability" => 0.99, "window_days" => 7}, db)
    {:ok, [r]} = SLOs.report(now, db: db)
    assert r.availability.burn["6h"] == 2.0 and r.availability.burn["30m"] == 2.0
    assert r.availability.slow and not r.availability.fast
    assert r.thresholds == %{fast: 3.36, slow: 1.4}

    {:ok, [quiet]} = SLOs.report(now, db: db, min_requests: 10 * 6 * 3600)
    refute quiet.availability.slow
  end

  test "a flag that starts is one slo_burn wire item, said once, kept across a restart, and cleared", %{db: db, now: now} do
    seed_shop(db, now)
    {:ok, _} = SLOs.save(%{"node" => "shop", "availability" => 0.995}, db)
    topic = "slo_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, topic)
    start_supervised!({SLOs, db: db, topic: topic, every_ms: nil, labels: %{"shop" => "Shop"}})

    {:ok, [r]} = SLOs.evaluate(SLOs, now)
    assert r.burning == %{"availability.fast" => now}
    assert_receive {:slo_status, [%{node: "shop"}]}

    assert [%{at: ^now, app: "shop", label: "Shop", member: nil, kind: "slo_burn", sev: "alert", head: head, text: text}] = SLOs.drain()
    assert head == "fast burn of the availability budget: 24.0x over 1h"
    assert text == "Target 99.5% of requests without a 5xx, 30-day window. Burn 24.0x over 1h and 24.0x over 5m; flagged at 14.4x (2% of the budget in 1h). Budget left: 30.4%."
    assert SLOs.drain() == []

    # still burning a minute later: not news again, nor after a restart
    {:ok, _} = SLOs.evaluate(SLOs, now + 1_000)
    assert SLOs.drain() == []
    stop_supervised!(SLOs)
    start_supervised!({SLOs, db: db, topic: topic, every_ms: nil})
    {:ok, _} = SLOs.evaluate(SLOs, now + 2_000)
    assert SLOs.drain() == []
    assert {:ok, [%{burning: %{"availability.fast" => ^now}}]} = SLOs.targets(db)

    # three hours on with nothing new on the tape: the last hour has no
    # requests, no burn, the flag is off and forgotten
    {:ok, [later]} = SLOs.evaluate(SLOs, now + 3 * @hour)
    refute later.availability.fast
    assert later.burning == %{}
    assert {:ok, [%{burning: %{}}]} = SLOs.targets(db)
  end

  test "an slo_burn item goes onto the tape's wire like any other", %{db: db, now: now} do
    seed_shop(db, now)
    {:ok, _} = SLOs.save(%{"node" => "shop", "availability" => 0.995}, db)
    start_supervised!({SLOs, db: db, every_ms: nil})
    {:ok, _} = SLOs.evaluate(SLOs, now)

    # what the ticker does: its own wire items ++ SLOs.drain()
    snap = %{attention: [], nodes: [%{id: "caddy", kind: "proxy", status: "working", hosts: [%{rps: 1.0, err_rps: 0.0}]}]}
    at = now + 5_000
    Tape.record(at, "{}", Tape.summary(snap, %{}, %{}, [] ++ SLOs.drain()))
    assert_receive {:tape_frame, %{at: ^at, wire: [%{kind: "slo_burn", sev: "alert"}]}}, 2_000
    assert {:ok, [%{kind: "slo_burn", app: "shop", sev: "alert", head: "fast burn" <> _}]} = Tape.wire(now - 1, at + 1, 10, db, ["slo_burn"])
  end

  test "the writeup has an SLOs section", %{db: db, now: now} do
    seed_shop(db, now)
    md = SLOs.writeup(now, [], db)
    assert md =~ "No error budget is set"
    {:ok, _} = SLOs.save(%{"node" => "shop", "availability" => 0.995, "latency_ms" => 500}, db)
    md = SLOs.writeup(now, [], db)
    assert md =~ "## SLOs"
    assert md =~ "| shop | availability | 99.5% | 99.652% | 30.4% | 24.0x | 4.2x | fast burn | 1,728,000 |"
    assert md =~ "the tape keeps 7 days"
    assert SLOs.writeup(now, ["other"], db) =~ "No error budget is set for these buildings"

    {:ok, w} = ObsFactor.Writeup.build(from: now - @hour, to: now, db: db, sections: ["slos"])
    assert w.markdown =~ "## SLOs"
    assert "slos" in ObsFactor.Writeup.sections()
  end

  test "over the channel: reports on join, a save replied and pushed to everyone", %{db: db, now: now} do
    seed_shop(db, now)
    {:ok, %{reports: [], thresholds: %{"30" => %{fast: 14.4}}}, socket} = subscribe_and_join(authed_socket("a"), ObsFactorWeb.SLOChannel, "slo")
    ref = push(socket, "save", %{"node" => "shop", "availability" => 0.995, "window_days" => 30, "by" => "a"})
    assert_reply ref, :ok, %{target: %{node: "shop", by: "a"}}
    assert_push "status", %{reports: [%{node: "shop", availability: %{requests: n}}]}
    assert n > 0
    ref = push(socket, "save", %{"node" => "shop", "availability" => 2})
    assert_reply ref, :error, %{error: "availability is a share" <> _}
    ref = push(socket, "delete", %{"node" => "shop"})
    assert_reply ref, :ok, %{deleted: "shop"}
    assert_push "status", %{reports: []}
    _ = db
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
