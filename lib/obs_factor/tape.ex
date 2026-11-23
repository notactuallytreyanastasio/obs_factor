defmodule ObsFactor.Tape do
  @moduledoc """
  The tape: every snapshot the ticker builds, kept in Postgres so the floor
  can be replayed as it was. `ObsFactor.History` keeps numbers per node for
  the charts; it cannot redraw a building that was on fire, a belt that was
  red or the attention strip at 03:12. The tape keeps the snapshot itself.

  ## What is kept

  One row per tick in `tape_frames`: the snapshot's JSON, gzipped (a 100 KB
  snapshot of the production box is about 11 KB), and beside it a summary
  that the timeline and the insights read without unpacking a frame:
  alerts, warnings, buildings down or blocked, requests and 5xx per second
  through the proxies, and the attention lines themselves (`fires`).

  Every tick is kept for `fine_ms` (6 hours); older than that, only the
  first frame of each minute (`minute_mark`); older than `keep_ms` (7 days),
  nothing. Except inside a saved window (`tape_windows`, `save_window/2`):
  there every frame is kept until the window is pruned. On the production box that is about 50 MB of fine frames and
  110 MB of minute frames. Thinning runs every 10 minutes.

  ## Where

  The objectives database (OBJECTIVES_PG_URL), through the same pool: the
  tape and the missions are read together (a fire on the timeline is an
  objective's event). No store, no tape: `record/2` does nothing and the
  `tape` channel answers with why.

  Writing is a cast: the ticker never waits on Postgres. A failed insert is
  logged once a minute and the frame is lost; the tape has a gap there,
  which the timeline draws as one.

  Every frame written is broadcast on `ObsFactor.PubSub` topic `"tape"` as
  `{:tape_frame, summary}`, so a timeline grows its live edge.
  """
  use GenServer
  require Logger

  @db ObsFactor.ObjectivesDB
  @topic "tape"
  @thin_every_ms 10 * 60_000
  @minute 60_000

  @ddl [
    """
    CREATE TABLE IF NOT EXISTS tape_frames (
      at timestamptz PRIMARY KEY,
      body bytea NOT NULL,
      minute_mark boolean NOT NULL,
      alerts integer NOT NULL,
      warns integer NOT NULL,
      down integer NOT NULL,
      blocked integer NOT NULL,
      rps real,
      err_rps real,
      fires jsonb NOT NULL
    )
    """,
    # the board (board.js): a few numbers per node, so a stretch of the tape
    # can be charted without unpacking a frame (added 2026-11-23)
    "ALTER TABLE tape_frames ADD COLUMN IF NOT EXISTS metrics jsonb",
    # windows: stretches someone saved. Their frames are never thinned.
    """
    CREATE TABLE IF NOT EXISTS tape_windows (
      id bigserial PRIMARY KEY,
      from_at timestamptz NOT NULL,
      to_at timestamptz NOT NULL,
      title text NOT NULL,
      note text,
      by text,
      created_at timestamptz NOT NULL DEFAULT now(),
      CHECK (to_at > from_at)
    )
    """,
    # pruning is undoable for an hour: pruned_at marks it, thinning still
    # spares its frames, and the hour after it the row is deleted
    "ALTER TABLE tape_windows ADD COLUMN IF NOT EXISTS pruned_at timestamptz"
  ]

  @undo "interval '1 hour'"

  # a frame inside a saved window is kept, whatever its age
  @unsaved "NOT EXISTS (SELECT 1 FROM tape_windows w WHERE tape_frames.at BETWEEN w.from_at AND w.to_at AND (w.pruned_at IS NULL OR w.pruned_at > now() - interval '1 hour'))"
  @max_window_ms 31 * 86_400_000

  # what the board keeps of `ObsFactor.History.metrics/2`, per node
  @board_keys ~w(rps err_rps p95_ms avg_ms in_flight cpu_cores mem_bytes commits_per_s connections cpu_used_cores mem_used_bytes disk_used_pct)a

  def topic, do: @topic
  def db, do: @db

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def enabled?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  # ---- writing -----------------------------------------------------------

  @doc """
  What the timeline needs of a snapshot without unpacking it. Requests and
  5xx are summed over the proxies' hosts (every request comes in through
  one); nil when a proxy's rate is unknown.
  """
  def summary(snapshot, metrics \\ %{}) do
    attention = Map.get(snapshot, :attention, [])
    nodes = snapshot.nodes
    hosts = for n <- nodes, n.kind == "proxy", h <- n.hosts || [], do: h

    sum = fn key ->
      vals = Enum.map(hosts, &Map.get(&1, key))
      if hosts == [] or Enum.any?(vals, &(not is_number(&1))), do: nil, else: Enum.sum(vals) / 1
    end

    %{
      alerts: Enum.count(attention, &(&1.severity == "alert")),
      warns: Enum.count(attention, &(&1.severity == "warn")),
      down: Enum.count(nodes, &(&1.status == "down")),
      blocked: Enum.count(nodes, &(&1.status == "blocked")),
      rps: sum.(:rps),
      err_rps: sum.(:err_rps),
      fires:
        for(a <- attention, a.severity in ["alert", "warn"], do: %{node: a.node, severity: a.severity, text: a.text})
        |> Enum.take(40),
      metrics: board(metrics)
    }
  end

  @doc false
  # node => %{key => number}, numbers rounded to 4 significant digits, nils
  # and nodes with nothing left dropped: about 2 KB a frame on production
  def board(metrics) do
    for {node, kv} <- metrics,
        m = for({k, v} <- Map.take(kv, @board_keys), is_number(v), into: %{}, do: {k, sig(v)}),
        m != %{},
        into: %{},
        do: {node, m}
  end

  defp sig(v) when v == 0, do: 0
  defp sig(v) when is_integer(v), do: v

  defp sig(v) do
    digits = 3 - trunc(:math.floor(:math.log10(abs(v))))
    if digits > 0, do: Float.round(v, min(digits, 15)), else: round(v)
  end

  @doc "Record one tick: its time, its JSON, its `summary/1`. Never blocks."
  def record(at_ms, json, summary, server \\ __MODULE__) do
    if enabled?(server), do: GenServer.cast(server, {:record, at_ms, json, summary})
    :ok
  end

  # ---- reading (in the caller, through the pool) ---------------------------

  @doc "`{:ok, %{from, to, frames}}` (ms; nils when empty) or `{:error, reason}`."
  def range(db \\ @db) do
    with {:ok, %{rows: [[from, to, n]]}} <-
           q(db, "SELECT min(at), max(at), count(*) FROM tape_frames", []) do
      {:ok, %{from: ms(from), to: ms(to), frames: n}}
    end
  end

  @doc """
  The timeline strip: `[from, to)` cut into `buckets` columns, each
  `[t, frames, alerts, warns, down, err_rps, rps]` (worst alerts, warnings,
  down and 5xx in the column; mean requests). Empty columns are left out:
  a gap on the tape.
  """
  def index(from_ms, to_ms, buckets, db \\ @db) when to_ms > from_ms and buckets in 1..2000 do
    step = max(1, div(to_ms - from_ms, buckets))

    sql = """
    SELECT floor((extract(epoch FROM at) * 1000 - $1) / $2)::bigint AS b, count(*),
           max(alerts), max(warns), max(down), max(err_rps), avg(rps)
    FROM tape_frames WHERE at >= $3 AND at < $4
    GROUP BY b ORDER BY b
    """

    with {:ok, %{rows: rows}} <- q(db, sql, [from_ms, step, dt(from_ms), dt(to_ms)]) do
      {:ok,
       %{
         from: from_ms,
         to: to_ms,
         step: step,
         buckets: for([b, n, a, w, d, e, r] <- rows, do: [from_ms + b * step, n, a, w, d, round3(e), round3(r)])
       }}
    end
  end

  @doc """
  The frame at `at_ms`: the last one at or before it, or the first after
  it when the tape starts later. `{:ok, at_ms, json, next_ms}` (`next_ms`:
  the frame after it, nil at the live edge, so a player knows when the
  picture next changes), `:none` or `{:error, reason}`.
  """
  def frame(at_ms, db \\ @db) do
    sql = """
    WITH f AS (
      (SELECT at, body FROM tape_frames WHERE at <= $1 ORDER BY at DESC LIMIT 1)
      UNION ALL
      (SELECT at, body FROM tape_frames WHERE at > $1 ORDER BY at LIMIT 1)
      LIMIT 1
    )
    SELECT f.at, f.body, (SELECT min(t.at) FROM tape_frames t WHERE t.at > f.at) FROM f
    """

    case q(db, sql, [dt(at_ms)]) do
      {:ok, %{rows: [[at, body, next]]}} -> {:ok, ms(at), :zlib.gunzip(body), ms(next)}
      {:ok, %{rows: []}} -> :none
      {:error, _} = e -> e
    end
  end

  @doc """
  What happened to the objectives in `[from, to]`, for the markers on the
  timeline: `[at, kind, objective_id, node, severity, title, by]`, oldest
  first, at most 600 (the newest).
  """
  def marks(from_ms, to_ms, db \\ @db) do
    sql = """
    SELECT * FROM (
      SELECT e.at, e.kind, o.id, o.node, o.severity, o.title, e.by
      FROM objective_events e JOIN objectives o ON o.id = e.objective_id
      WHERE e.at >= $1 AND e.at <= $2
        AND e.kind IN ('seen', 'came back', 'pinned', 'looking', 'crossed off', 'cleared itself', 'reopened')
      ORDER BY e.at DESC LIMIT 600
    ) m ORDER BY at
    """

    with {:ok, %{rows: rows}} <- q(db, sql, [dt(from_ms), dt(to_ms)]) do
      {:ok, Enum.map(rows, fn [at | rest] -> [ms(at) | rest] end)}
    end
  end

  @doc """
  The board's series for `[from, to]`: at most `points` frames, evenly
  spaced over the frames in the window (every k-th), each `[at, metrics]`
  with metrics as `summary/2` keeps them (`%{}` for frames written before
  the column existed).
  """
  def series(from_ms, to_ms, points, db \\ @db) when points in 1..2000 do
    sql = """
    WITH f AS (
      SELECT at, metrics, row_number() OVER (ORDER BY at DESC) - 1 AS i, count(*) OVER () AS n
      FROM tape_frames WHERE at >= $1 AND at <= $2
    )
    SELECT at, coalesce(metrics, '{}'::jsonb) FROM f
    WHERE i % greatest(1, ceil(n::numeric / $3)::int) = 0
    ORDER BY at
    """

    with {:ok, %{rows: rows}} <- q(db, sql, [dt(from_ms), dt(to_ms), points]) do
      {:ok, Enum.map(rows, fn [at, m] -> [ms(at), m] end)}
    end
  end

  @doc """
  The error lanes: for each node and severity, the runs of frames in
  `[from, to]` where it had an attention line, a gap of more than 90 s
  ending a run (a minute frame is 60 s from the next). `[node, severity,
  from, to, frames, text]` (text: the last line of the run), oldest first,
  at most 3000.
  """
  def lanes(from_ms, to_ms, db \\ @db) do
    sql = """
    WITH e AS (
      SELECT f.at, x->>'node' AS node, x->>'severity' AS sev, x->>'text' AS text
      FROM tape_frames f, jsonb_array_elements(f.fires) x
      WHERE f.at >= $1 AND f.at <= $2
    ),
    g AS (
      SELECT *, CASE WHEN lag(at) OVER w IS NULL OR at - lag(at) OVER w > interval '90 seconds' THEN 1 ELSE 0 END AS brk
      FROM e WINDOW w AS (PARTITION BY node, sev ORDER BY at)
    ),
    r AS (SELECT *, sum(brk) OVER (PARTITION BY node, sev ORDER BY at) AS run FROM g)
    SELECT node, sev, min(at), max(at), count(*), (array_agg(text ORDER BY at DESC))[1]
    FROM r GROUP BY node, sev, run ORDER BY min(at) LIMIT 3000
    """

    with {:ok, %{rows: rows}} <- q(db, sql, [dt(from_ms), dt(to_ms)]) do
      {:ok, Enum.map(rows, fn [n, s, a, b, c, t] -> [n, s, ms(a), ms(b), c, t] end)}
    end
  end

  # ---- windows ----------------------------------------------------------

  @window_cols "id, from_at, to_at, title, note, by, created_at, pruned_at, (SELECT count(*) FROM tape_frames f WHERE f.at BETWEEN w.from_at AND w.to_at) AS frames"

  @doc """
  Every saved window, newest stretch first, and those pruned in the last
  hour (`pruned_at` set: they can still be restored): `{:ok, [window]}`.
  """
  def windows(db \\ @db) do
    sql = "SELECT #{@window_cols} FROM tape_windows w WHERE pruned_at IS NULL OR pruned_at > now() - #{@undo} ORDER BY from_at DESC"

    with {:ok, r} <- q(db, sql, []) do
      {:ok, Enum.map(r.rows, &window_row/1)}
    end
  end

  @doc """
  Save a window (`%{"from", "to", "title", "note", "by"}`), or change one
  (`"id"` too: its edges, which is how one is trimmed, its title, its
  note). `{:ok, window}` or `{:error, reason}`.
  """
  def save_window(attrs, db \\ @db) do
    with {:ok, f, t} <- edges(attrs),
         {:ok, title} <- text(attrs["title"], 120, "untitled window"),
         {:ok, note} <- text(attrs["note"], 2000, nil),
         {:ok, by} <- text(attrs["by"], 60, nil) do
      case attrs["id"] do
        id when is_integer(id) ->
          # a note sent (even empty) replaces the note; none sent keeps it
          set_note = if Map.has_key?(attrs, "note"), do: "$5", else: "coalesce($5, note)"

          write_window(db, "UPDATE tape_windows w SET from_at = $2, to_at = $3, title = $4, note = #{set_note} WHERE id = $1 AND pruned_at IS NULL RETURNING #{@window_cols}",
            [id, dt(f), dt(t), title, note], id)

        nil ->
          write_window(db, "INSERT INTO tape_windows AS w (from_at, to_at, title, note, by) VALUES ($1, $2, $3, $4, $5) RETURNING #{@window_cols}",
            [dt(f), dt(t), title, note, by], nil)

        other ->
          {:error, "a window id is an integer, got #{inspect(other)}"}
      end
    end
  end

  defp write_window(db, sql, params, id) do
    case q(db, sql, params) do
      {:ok, %{rows: [row]}} -> {:ok, window_row(row)}
      {:ok, %{rows: []}} -> {:error, "no window #{id}: pruned already?"}
      {:error, e} -> {:error, message(e)}
    end
  end

  @doc """
  Prune windows by id: marked, not deleted. For an hour they can be
  restored and their frames are still spared; after that the rows go and
  the frames are thinned like any other. `{:ok, pruned_ids}`.
  """
  def prune_windows(ids, db \\ @db), do: mark(ids, "now()", "pruned_at IS NULL", db)

  @doc "Undo a prune from the last hour. `{:ok, restored_ids}`."
  def restore_windows(ids, db \\ @db), do: mark(ids, "NULL", "pruned_at > now() - #{@undo}", db)

  defp mark(ids, value, where, db) when is_list(ids) do
    if ids != [] and Enum.all?(ids, &is_integer/1) do
      with {:ok, r} <- q(db, "UPDATE tape_windows SET pruned_at = #{value} WHERE id = ANY($1) AND #{where} RETURNING id", [ids]) do
        {:ok, Enum.map(r.rows, &hd/1)}
      end
    else
      {:error, "expected a list of integer window ids, got #{inspect(ids)}"}
    end
  end

  defp mark(ids, _, _, _), do: {:error, "expected a list of integer window ids, got #{inspect(ids)}"}

  defp edges(%{"from" => f, "to" => t}) when is_integer(f) and is_integer(t) and t > f and t - f <= @max_window_ms,
    do: {:ok, f, t}

  defp edges(a), do: {:error, "a window is from and to, integer unix ms, from first, at most 31 days: got #{inspect(Map.take(a, ["from", "to"]))}"}

  defp text(nil, _, default), do: {:ok, default}
  defp text(s, max, default) when is_binary(s) do
    case String.trim(s) do
      "" -> {:ok, default}
      t -> {:ok, String.slice(t, 0, max)}
    end
  end

  defp text(other, _, _), do: {:error, "expected text, got #{inspect(other)}"}

  defp window_row([id, f, t, title, note, by, created, pruned, frames]),
    do: %{id: id, from: ms(f), to: ms(t), title: title, note: note, by: by, created_at: ms(created), pruned_at: ms(pruned), frames: frames}

  @doc """
  Per node, how long it burned in `[from, to]` according to the tape: each
  frame counts until the next one (at most 2 minutes, so a gap is not a
  fire). `[%{node, severity, ms, first, last, text}]`.
  """
  def burn(from_ms, to_ms, db \\ @db) do
    sql = """
    WITH f AS (
      SELECT at, fires,
             greatest(least(coalesce(lead(at) OVER (ORDER BY at), least(now(), $2)) - at, interval '2 minutes'), interval '0') AS dur
      FROM tape_frames WHERE at >= $1 AND at <= $2
    )
    SELECT e->>'node', e->>'severity', extract(epoch FROM sum(dur)) * 1000, min(f.at), max(f.at),
           (array_agg(e->>'text' ORDER BY f.at DESC))[1]
    FROM f, jsonb_array_elements(f.fires) e
    GROUP BY 1, 2
    """

    with {:ok, %{rows: rows}} <- q(db, sql, [dt(from_ms), dt(to_ms)]) do
      {:ok,
       for [node, sev, total, first, last, text] <- rows do
         %{node: node, severity: sev, ms: round(to_f(total)), first: ms(first), last: ms(last), text: text}
       end}
    end
  end

  @doc """
  The calm and the worst of `[from, to]`: the share of tape time with no
  alert, the last frame with one (ever), and the worst moments by 5xx and
  by alerts.
  """
  def weather(from_ms, to_ms, db \\ @db) do
    span = """
    WITH f AS (
      SELECT at, alerts,
             greatest(least(coalesce(lead(at) OVER (ORDER BY at), least(now(), $2)) - at, interval '2 minutes'), interval '0') AS dur
      FROM tape_frames WHERE at >= $1 AND at <= $2
    )
    SELECT extract(epoch FROM sum(dur)) * 1000, extract(epoch FROM sum(dur) FILTER (WHERE alerts = 0)) * 1000, count(*)
    FROM f
    """

    peaks = """
    SELECT at, err_rps, alerts, down FROM tape_frames
    WHERE at >= $1 AND at <= $2 AND err_rps > 0 ORDER BY err_rps DESC LIMIT 40
    """

    worst = """
    SELECT at, alerts, warns, down FROM tape_frames
    WHERE at >= $1 AND at <= $2 AND (alerts > 0 OR down > 0) ORDER BY alerts + down DESC, at DESC LIMIT 1
    """

    args = [dt(from_ms), dt(to_ms)]

    with {:ok, %{rows: [[total, calm, n]]}} <- q(db, span, args),
         {:ok, %{rows: [[last_alert]]}} <- q(db, "SELECT max(at) FROM tape_frames WHERE alerts > 0", []),
         {:ok, %{rows: peak_rows}} <- q(db, peaks, args),
         {:ok, %{rows: worst_rows}} <- q(db, worst, args) do
      {:ok,
       %{
         frames: n,
         tape_ms: round(to_f(total)),
         calm_ms: round(to_f(calm)),
         last_alert: ms(last_alert),
         # one peak per minute: a burst of five ticks is one peak
         peaks:
           peak_rows
           |> Enum.uniq_by(fn [at | _] -> div(ms(at), @minute) end)
           |> Enum.take(3)
           |> Enum.map(fn [at, e, a, d] -> %{at: ms(at), err_rps: round3(e), alerts: a, down: d} end),
         worst:
           case worst_rows do
             [[at, a, w, d]] -> %{at: ms(at), alerts: a, warns: w, down: d}
             [] -> nil
           end
       }}
    end
  end

  # ---- the server --------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      db: Keyword.get(opts, :db, @db),
      topic: Keyword.get(opts, :topic, @topic),
      fine_ms: Keyword.get(opts, :fine_ms, 6 * 3_600_000),
      keep_ms: Keyword.get(opts, :keep_ms, 7 * 86_400_000),
      minute: nil,
      ready: false,
      logged_at: 0
    }

    Process.send_after(self(), :thin, Keyword.get(opts, :thin_first_ms, 60_000))
    {:ok, state, {:continue, :schema}}
  end

  @impl true
  def handle_continue(:schema, state), do: {:noreply, schema(state)}

  defp schema(state) do
    case Enum.reduce_while(@ddl, :ok, fn sql, :ok ->
           case q(state.db, sql, []) do
             {:ok, _} -> {:cont, :ok}
             e -> {:halt, e}
           end
         end) do
      :ok -> %{state | ready: true}
      {:error, e} -> complain(state, "tape: cannot create its table", e)
    end
  end

  @impl true
  def handle_cast({:record, at_ms, json, summary}, %{ready: false} = state) do
    state = schema(state)
    if state.ready, do: handle_cast({:record, at_ms, json, summary}, state), else: {:noreply, state}
  end

  def handle_cast({:record, at_ms, json, summary}, state) do
    minute = div(at_ms, @minute)
    mark = minute != state.minute

    sql = """
    INSERT INTO tape_frames (at, body, minute_mark, alerts, warns, down, blocked, rps, err_rps, fires, metrics)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) ON CONFLICT (at) DO NOTHING
    """

    params = [
      dt(at_ms),
      :zlib.gzip(json),
      mark,
      summary.alerts,
      summary.warns,
      summary.down,
      summary.blocked,
      summary.rps,
      summary.err_rps,
      summary.fires,
      Map.get(summary, :metrics, %{})
    ]

    case q(state.db, sql, params) do
      {:ok, _} ->
        tick = summary |> Map.drop([:fires]) |> Map.merge(%{at: at_ms, fires: length(summary.fires), top: Enum.take(summary.fires, 6)})
        Phoenix.PubSub.broadcast(ObsFactor.PubSub, state.topic, {:tape_frame, tick})
        {:noreply, %{state | minute: minute}}

      {:error, e} ->
        {:noreply, complain(state, "tape: a frame was not written", e)}
    end
  end

  @impl true
  def handle_info(:thin, state) do
    Process.send_after(self(), :thin, @thin_every_ms)
    {:noreply, thin(state, System.system_time(:millisecond))}
  end

  @doc false
  def thin(state, now_ms) do
    with {:ok, a} <-
           q(state.db, "DELETE FROM tape_frames WHERE at < $1 AND NOT minute_mark AND #{@unsaved}", [dt(now_ms - state.fine_ms)]),
         {:ok, b} <- q(state.db, "DELETE FROM tape_frames WHERE at < $1 AND #{@unsaved}", [dt(now_ms - state.keep_ms)]),
         {:ok, _} <- q(state.db, "DELETE FROM tape_windows WHERE pruned_at < now() - #{@undo}", []) do
      if a.num_rows + b.num_rows > 0,
        do:
          Logger.info("tape thinned: #{a.num_rows} fine frames, #{b.num_rows} old frames",
            event: "tape.thinned",
            fine: a.num_rows,
            old: b.num_rows
          )

      state
    else
      {:error, e} -> complain(state, "tape: thinning failed", e)
    end
  end

  # once a minute, not once a tick
  defp complain(state, what, e) do
    now = System.monotonic_time(:millisecond)

    if now - state.logged_at > 60_000 do
      Logger.error("#{what}: #{message(e)}", event: "tape.failed", reason: message(e))
      %{state | logged_at: now}
    else
      state
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)

  defp to_f(nil), do: 0.0
  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n), do: n / 1

  defp round3(nil), do: nil
  defp round3(%Decimal{} = d), do: d |> Decimal.to_float() |> round3()
  defp round3(n), do: Float.round(n / 1, 3)

  def message(%{message: m}) when is_binary(m), do: m
  def message(%Postgrex.Error{} = e), do: Exception.message(e)
  def message(m) when is_binary(m), do: m
  def message(other), do: inspect(other)
end
