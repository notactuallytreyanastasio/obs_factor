defmodule ObsFactor.Rollups do
  @moduledoc """
  Hourly rollups: what the tape said about each hour, kept for 13 months
  after the tape itself has thinned the frames away (every tick for 6 h,
  one a minute for 7 days, then nothing: `ObsFactor.Tape.thin/2`).

  One row per UTC hour in `tape_rollups` (objectives database, through the
  same pool as the tape), computed once from the frames of that hour:

    * `frames`, `tape_s` (seconds of tape: each frame counts until the next,
      at most 2 minutes, so a gap is not counted)
    * `alerts_max`, `warns_max`, `down_max`, `blocked_max`; `alert_s` and
      `warn_s`, the seconds with at least one alert (warning) on the floor
      (the "alert-minutes", in seconds)
    * `rps_mean`, `rps_max`, `err_rps_mean`, `err_rps_max`: through the
      proxies, as the tape's columns
    * `nodes`: per node with a request rate on the board (the node's own
      hostnames summed, `ObsFactor.History`), `rps` and `err_rps`
      `{mean, max}`
    * `beam`: per `beam:` key, `app` and `procs`, `mem`, `reds`, `rq`,
      `mbox` `{mean, max}`
    * `dbs`: per `pg:` key, `app` and `conns`, `commits` `{mean, max}`
    * `lanes`: per node, `alert_s` and `warn_s` (seconds it had an
      attention line of that severity)
    * `wire`: wire items by kind; `wire_apps`: by app, then kind

  Means are weighted by time, so an hour that is half fine frames (5 s)
  and half minute frames (60 s) is not dominated by the fine half.

  The job (`ObsFactor.Jobs.Rollup`, Oban cron every 5 minutes, `run/3`)
  looks for hours that are over (a minute's grace for the last writes) and have frames but
  no row, oldest first, and rolls them up: on start it catches up on
  everything the tape still has. Rolling an hour again (`roll_hour/2`)
  replaces its row, so a rollup can always be recomputed while the frames
  are there. Rows older than `keep_months` (13) are deleted.

  Readers: `summarize/3` (any range, hours read from the table, the edges
  and hours not yet rolled computed from the tape), `index/4` (the
  timeline's strip, falling back to rollups before the tape starts), and
  `ObsFactor.Writeup`.
  """

  alias ObsFactor.Tape

  @hour 3_600_000
  @grace_ms 60_000
  @beam_fields ~w(procs mem reds rq mbox)
  @db_fields ~w(conns commits)
  @node_fields ~w(rps err_rps)

  @ddl """
  CREATE TABLE IF NOT EXISTS tape_rollups (
    hour timestamptz PRIMARY KEY,
    frames integer NOT NULL,
    tape_s double precision NOT NULL,
    alerts_max integer,
    warns_max integer,
    down_max integer,
    blocked_max integer,
    alert_s double precision NOT NULL,
    warn_s double precision NOT NULL,
    rps_mean double precision,
    rps_max double precision,
    err_rps_mean double precision,
    err_rps_max double precision,
    nodes jsonb NOT NULL,
    beam jsonb NOT NULL,
    dbs jsonb NOT NULL,
    lanes jsonb NOT NULL,
    wire jsonb NOT NULL,
    wire_apps jsonb NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT now()
  )
  """

  @cols ~w(frames tape_s alerts_max warns_max down_max blocked_max alert_s warn_s rps_mean rps_max err_rps_mean err_rps_max nodes beam dbs lanes wire wire_apps)a


  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # ---- computing -----------------------------------------------------------

  # the frames of [$1, $2) with how long each counts (seconds): until the
  # next frame, cut at $2 and at 2 minutes. The frames of the 2 minutes
  # after $2 are read only to know when the last one inside ends.
  @frames """
  g AS (
    SELECT at, alerts, warns, down, blocked, rps, err_rps, fires, metrics, lead(at) OVER (ORDER BY at) AS nx
    FROM tape_frames WHERE at >= $1::timestamptz AND at < $2::timestamptz + interval '2 minutes'
  ),
  f AS (
    SELECT *, extract(epoch FROM least(greatest(least(coalesce(nx, least(now(), $2::timestamptz)), $2::timestamptz) - at, interval '0'), interval '2 minutes'))::float8 AS d
    FROM g WHERE at < $2::timestamptz
  )
  """

  @doc """
  What the tape says about `[from, to)` (unix ms), as one rollup:
  `{:ok, %{frames, tape_s, ..., nodes, beam, dbs, lanes, wire, wire_apps}}`
  (`frames: 0` when the tape has nothing there).
  """
  def compute(from_ms, to_ms, db \\ Tape.db()) when to_ms > from_ms do
    args = [dt(from_ms), dt(to_ms)]

    totals = """
    WITH #{@frames}
    SELECT count(*), coalesce(sum(d), 0), max(alerts), max(warns), max(down), max(blocked),
           coalesce(sum(d) FILTER (WHERE alerts > 0), 0), coalesce(sum(d) FILTER (WHERE warns > 0), 0),
           coalesce(sum(rps * d) / nullif(sum(d) FILTER (WHERE rps IS NOT NULL), 0), avg(rps)), max(rps),
           coalesce(sum(err_rps * d) / nullif(sum(d) FILTER (WHERE err_rps IS NOT NULL), 0), avg(err_rps)), max(err_rps)
    FROM f
    """

    metrics = """
    WITH #{@frames}
    SELECT m.k, x.fld, max(m.kv->>'app'),
           coalesce(sum(x.v::float8 * f.d) / nullif(sum(f.d), 0), avg(x.v::float8)), max(x.v::float8)
    FROM f, jsonb_each(f.metrics) AS m(k, kv), jsonb_each(m.kv) AS x(fld, v)
    WHERE f.metrics IS NOT NULL AND jsonb_typeof(m.kv) = 'object' AND jsonb_typeof(x.v) = 'number'
      AND ((starts_with(m.k, 'beam:') AND x.fld = ANY($3))
        OR (starts_with(m.k, 'pg:') AND x.fld = ANY($4))
        OR (strpos(m.k, ':') = 0 AND x.fld = ANY($5)))
    GROUP BY m.k, x.fld
    """

    lanes = """
    WITH #{@frames}
    SELECT e->>'node', e->>'severity', sum(f.d)
    FROM f, jsonb_array_elements(f.fires) e
    GROUP BY 1, 2
    """

    wire = "SELECT coalesce(app, ''), kind, count(*) FROM tape_wire WHERE at >= $1 AND at < $2 GROUP BY 1, 2"

    with {:ok, %{rows: [[n, tape_s, am, wm, dm, bm, as, ws, rmean, rmax, emean, emax]]}} <- q(db, totals, args),
         {:ok, %{rows: mrows}} <- q(db, metrics, args ++ [@beam_fields, @db_fields, @node_fields]),
         {:ok, %{rows: lrows}} <- q(db, lanes, args),
         {:ok, %{rows: wrows}} <- q(db, wire, args) do
      {:ok,
       %{
         frames: n,
         tape_s: f(tape_s),
         alerts_max: am,
         warns_max: wm,
         down_max: dm,
         blocked_max: bm,
         alert_s: f(as),
         warn_s: f(ws),
         rps_mean: f(rmean),
         rps_max: f(rmax),
         err_rps_mean: f(emean),
         err_rps_max: f(emax),
         nodes: keyed(mrows, &(not String.contains?(&1, ":")), false),
         beam: keyed(mrows, &String.starts_with?(&1, "beam:"), true),
         dbs: keyed(mrows, &String.starts_with?(&1, "pg:"), true),
         lanes:
           Enum.reduce(lrows, %{}, fn [node, sev, s], acc ->
             if sev in ["alert", "warn"],
               do: Map.update(acc, node, %{"alert_s" => 0.0, "warn_s" => 0.0} |> Map.put(sev <> "_s", f(s)), &Map.put(&1, sev <> "_s", f(s))),
               else: acc
           end),
         wire: Enum.reduce(wrows, %{}, fn [_, kind, c], acc -> Map.update(acc, kind, c, &(&1 + c)) end),
         wire_apps: Enum.reduce(wrows, %{}, fn [app, kind, c], acc -> Map.update(acc, app, %{kind => c}, &Map.put(&1, kind, c)) end)
       }}
    end
  end

  # [key, field, app, mean, max] rows => key => %{"app", field => %{"mean", "max"}}
  defp keyed(rows, want?, with_app) do
    Enum.reduce(rows, %{}, fn [k, fld, app, mean, max], acc ->
      if want?.(k) do
        base = if with_app and app, do: %{"app" => app}, else: %{}
        Map.update(acc, k, Map.put(base, fld, %{"mean" => f(mean), "max" => f(max)}), &Map.put(&1, fld, %{"mean" => f(mean), "max" => f(max)}))
      else
        acc
      end
    end)
  end

  @doc """
  Roll up the hour that starts at `hour_ms` (a multiple of an hour) and
  keep it, replacing any row it had: `{:ok, rollup}`, `{:ok, :empty}` when
  the tape has no frame in it (nothing is written), or `{:error, reason}`.
  """
  def roll_hour(hour_ms, db \\ Tape.db()) when rem(hour_ms, @hour) == 0 do
    with :ok <- ensure(db),
         {:ok, r} <- compute(hour_ms, hour_ms + @hour, db) do
      if r.frames == 0 do
        {:ok, :empty}
      else
        n = length(@cols)
        sets = Enum.map_join(@cols, ", ", &"#{&1} = EXCLUDED.#{&1}")

        sql = """
        INSERT INTO tape_rollups (hour, #{Enum.join(@cols, ", ")}) VALUES ($1, #{Enum.map_join(2..(n + 1), ", ", &"$#{&1}")})
        ON CONFLICT (hour) DO UPDATE SET #{sets}, computed_at = now()
        """

        with {:ok, _} <- q(db, sql, [dt(hour_ms) | Enum.map(@cols, &Map.fetch!(r, &1))]),
             do: {:ok, Map.put(r, :hour, hour_ms)}
      end
    end
  end

  @doc """
  The hours that are over by `now_ms` (less a minute's grace), have frames
  on the tape and no rollup yet, oldest first, at most `limit`: unix ms.
  """
  def pending(now_ms, limit \\ 500, db \\ Tape.db()) do
    cutoff = div(now_ms - @grace_ms, @hour) * @hour

    sql = """
    SELECT DISTINCT floor(extract(epoch FROM at) / 3600)::bigint FROM tape_frames WHERE at < $1
    EXCEPT SELECT floor(extract(epoch FROM hour) / 3600)::bigint FROM tape_rollups
    ORDER BY 1 LIMIT $2
    """

    with :ok <- ensure(db), {:ok, %{rows: rows}} <- q(db, sql, [dt(cutoff), limit]) do
      {:ok, for([h] <- rows, do: h * @hour)}
    end
  end

  @doc """
  One pass of the job: roll up every pending hour, then delete rows older
  than `keep_months`. `{:ok, %{rolled: [hour_ms], pruned: n}}`.
  """
  def run(now_ms, db \\ Tape.db(), keep_months \\ 13) do
    with {:ok, hours} <- pending(now_ms, 500, db),
         {:ok, rolled} <- roll_all(hours, db, []),
         {:ok, %{num_rows: pruned}} <-
           q(db, "DELETE FROM tape_rollups WHERE hour < $1", [now_ms |> dt() |> DateTime.shift(month: -keep_months)]) do
      {:ok, %{rolled: rolled, pruned: pruned}}
    end
  end

  defp roll_all([], _db, acc), do: {:ok, Enum.reverse(acc)}

  defp roll_all([h | rest], db, acc) do
    case roll_hour(h, db) do
      {:ok, :empty} -> roll_all(rest, db, acc)
      {:ok, _} -> roll_all(rest, db, [h | acc])
      {:error, _} = e -> e
    end
  end

  # ---- reading ---------------------------------------------------------------

  @doc "When the tape's first frame is: `{:ok, unix_ms | nil}`."
  def tape_start(db \\ Tape.db()) do
    with {:ok, %{rows: [[start]]}} <- q(db, "SELECT min(at) FROM tape_frames", []), do: {:ok, ms(start)}
  end

  @doc "The kept rollups whose hour starts in `[from, to)`, oldest first: `{:ok, [rollup]}` (with `hour`, unix ms)."
  def hours(from_ms, to_ms, db \\ Tape.db()) do
    sql = "SELECT hour, #{Enum.join(@cols, ", ")} FROM tape_rollups WHERE hour >= $1 AND hour < $2 ORDER BY hour"

    with :ok <- ensure(db), {:ok, %{rows: rows}} <- q(db, sql, [dt(from_ms), dt(to_ms)]) do
      {:ok, Enum.map(rows, &row/1)}
    end
  end

  defp row([hour | vals]) do
    @cols
    |> Enum.zip(vals)
    |> Map.new()
    |> Map.put(:hour, ms(hour))
  end

  @doc """
  `[from, to)` as one rollup, with `hours` (how many went into it) and
  `widened` (true when an edge hour was off the tape and its whole kept
  rollup was used instead): whole hours from the table; edges, and hours
  the job has not rolled yet, computed from the tape when it has them.
  `{:ok, rollup}`; `frames: 0` when nothing is known of the range.
  """
  def summarize(from_ms, to_ms, db \\ Tape.db()) when to_ms > from_ms do
    first = div(from_ms, @hour) * @hour

    with {:ok, kept} <- hours(first, to_ms, db),
         {:ok, %{rows: on_tape}} <-
           q(db, "SELECT DISTINCT floor(extract(epoch FROM at) / 3600)::bigint FROM tape_frames WHERE at >= $1 AND at < $2", [dt(from_ms), dt(to_ms)]) do
      kept = Map.new(kept, &{&1.hour, &1})
      taped = MapSet.new(on_tape, fn [h] -> h * @hour end)

      parts =
        Stream.iterate(first, &(&1 + @hour))
        |> Enum.take_while(&(&1 < to_ms))
        |> Enum.flat_map(fn h ->
          whole = h >= from_ms and h + @hour <= to_ms

          cond do
            whole and Map.has_key?(kept, h) ->
              [{kept[h], false}]

            MapSet.member?(taped, h) ->
              case compute(max(h, from_ms), min(h + @hour, to_ms), db) do
                {:ok, %{frames: n} = r} when n > 0 -> [{r, false}]
                _ -> if kept[h], do: [{kept[h], true}], else: []
              end

            Map.has_key?(kept, h) ->
              [{kept[h], true}]

            true ->
              []
          end
        end)

      {:ok, parts |> Enum.map(&elem(&1, 0)) |> combine() |> Map.put(:widened, Enum.any?(parts, &elem(&1, 1)))}
    end
  end

  @doc "Several rollups as one: sums, maxima, means weighted by tape time."
  def combine(list) do
    w = fn r -> r.tape_s || 0.0 end

    mean = fn get ->
      pts = for r <- list, v = get.(r), is_number(v), do: {v, w.(r)}
      total = pts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      cond do
        pts == [] -> nil
        total > 0 -> Enum.sum(for {v, wt} <- pts, do: v * wt) / total
        true -> Enum.sum(Enum.map(pts, &elem(&1, 0))) / length(pts)
      end
    end

    top = fn get -> list |> Enum.map(get) |> Enum.filter(&is_number/1) |> Enum.max(fn -> nil end) end

    %{
      hours: length(list),
      frames: list |> Enum.map(& &1.frames) |> Enum.sum(),
      tape_s: list |> Enum.map(w) |> Enum.sum() |> f(),
      alerts_max: top.(& &1.alerts_max),
      warns_max: top.(& &1.warns_max),
      down_max: top.(& &1.down_max),
      blocked_max: top.(& &1.blocked_max),
      alert_s: list |> Enum.map(& &1.alert_s) |> Enum.sum() |> f(),
      warn_s: list |> Enum.map(& &1.warn_s) |> Enum.sum() |> f(),
      rps_mean: mean.(& &1.rps_mean),
      rps_max: top.(& &1.rps_max),
      err_rps_mean: mean.(& &1.err_rps_mean),
      err_rps_max: top.(& &1.err_rps_max),
      nodes: combine_keyed(list, :nodes, w),
      beam: combine_keyed(list, :beam, w),
      dbs: combine_keyed(list, :dbs, w),
      lanes: sum_maps(Enum.map(list, & &1.lanes)),
      wire: sum_maps(Enum.map(list, & &1.wire)),
      wire_apps: list |> Enum.map(& &1.wire_apps) |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _, a, b -> sum_maps([a, b]) end))
    }
  end

  defp combine_keyed(list, field, w) do
    list
    |> Enum.flat_map(fn r -> for {k, v} <- Map.get(r, field) || %{}, do: {k, v, w.(r)} end)
    |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
    |> Map.new(fn {k, pts} ->
      app = Enum.find_value(pts, fn {v, _} -> v["app"] end)
      fields = pts |> Enum.flat_map(fn {v, _} -> Map.keys(v) end) |> Enum.uniq() |> Enum.reject(&(&1 == "app"))

      stats =
        Map.new(fields, fn fld ->
          vals = for {v, wt} <- pts, s = v[fld], is_map(s), do: {s, wt}
          total = vals |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          means = for {s, wt} <- vals, is_number(s["mean"]), do: {s["mean"], wt}

          mean =
            cond do
              means == [] -> nil
              total > 0 -> Enum.sum(for {m, wt} <- means, do: m * wt) / max(Enum.sum(Enum.map(means, &elem(&1, 1))), 1.0e-9)
              true -> Enum.sum(Enum.map(means, &elem(&1, 0))) / length(means)
            end

          {fld, %{"mean" => mean, "max" => vals |> Enum.map(&elem(&1, 0)["max"]) |> Enum.filter(&is_number/1) |> Enum.max(fn -> nil end)}}
        end)

      {k, if(app, do: Map.put(stats, "app", app), else: stats)}
    end)
  end

  # %{k => number | %{k => number}} summed key by key
  defp sum_maps(maps) do
    Enum.reduce(maps, %{}, fn m, acc ->
      Map.merge(acc, m || %{}, fn
        _, a, b when is_map(a) and is_map(b) -> sum_maps([a, b])
        _, a, b -> a + b
      end)
    end)
  end

  @doc """
  The timeline's strip as `ObsFactor.Tape.index/4`, and where the window
  starts before the tape, the columns before it from the hourly rollups:
  per column, the rollups' frames (an hour's shared out over its
  columns), the worst alerts, warnings, down
  and 5xx (each hour's max) and requests (time-weighted mean). Adds
  `rollups_to`: unix ms up to which the columns are rollups (the tape's
  first frame), nil when none are.
  """
  def index(from_ms, to_ms, buckets, db \\ Tape.db()) do
    with {:ok, idx} <- Tape.index(from_ms, to_ms, buckets, db),
         {:ok, start} <- tape_start(db) do
      start = start || to_ms

      if from_ms >= start do
        {:ok, Map.put(idx, :rollups_to, nil)}
      else
        upto = min(start, to_ms)

        with {:ok, rows} <- hours(div(from_ms, @hour) * @hour, upto, db) do
          step = idx.step
          taken = MapSet.new(idx.buckets, &hd/1)

          cols =
            rows
            |> Enum.flat_map(fn r ->
              a = max(r.hour, from_ms)
              b = min(r.hour + @hour, upto)
              # an hour over several columns: each gets its share of the frames
              if b <= a do
                []
              else
                for i <- div(a - from_ms, step)..div(b - 1 - from_ms, step)//1 do
                  t = from_ms + i * step
                  {t, %{r | frames: round(r.frames * (min(t + step, b) - max(t, a)) / @hour)}}
                end
              end
            end)
            |> Enum.reject(fn {t, _} -> MapSet.member?(taken, t) or t >= to_ms end)
            |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
            |> Enum.map(fn {t, rs} ->
              c = combine(rs)
              [t, c.frames, c.alerts_max || 0, c.warns_max || 0, c.down_max || 0, r3(c.err_rps_max), r3(c.rps_mean)]
            end)

          {:ok, %{idx | buckets: Enum.sort_by(cols ++ idx.buckets, &hd/1)} |> Map.put(:rollups_to, if(cols == [], do: nil, else: start))}
        end
      end
    end
  end

  # ---- helpers -----------------------------------------------------------------

  @doc false
  def ensure(db) do
    case q(db, @ddl, []) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp f(nil), do: nil
  defp f(%Decimal{} = d), do: Decimal.to_float(d)
  defp f(n), do: n / 1

  defp r3(nil), do: nil
  defp r3(n), do: Float.round(n / 1, 3)

  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)
end
