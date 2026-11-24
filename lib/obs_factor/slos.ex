defmodule ObsFactor.SLOs do
  @moduledoc """
  Error budgets per app: a target someone set for a building (a topology
  node id), measured from the tape (`ObsFactor.Tape`), with how much of the
  budget is left and how fast it is burning.

  ## Targets

  One row per node in `slo_targets`, in the objectives database next to the
  tape:

    * `availability` - the share of requests that must not be a 5xx, e.g.
      `0.995`. Required.
    * `latency_ms`, `latency_target` - optional: the share of requests
      (`latency_target`, 0.99 when not given) that must be served while the
      node's p95 is at most `latency_ms`.
    * `window_days` - 7 or 30, rolling.

  ## What is measured, and from where

  Each tape frame's `metrics` (`ObsFactor.Tape.summary/4`, from
  `ObsFactor.History.metrics/2`) keeps per node `rps` and `err_rps`: the sum
  over the node's hosts at the proxy, so only nodes the proxy routes to by
  hostname have `err_rps`. A node reached only by path routes has `rps`
  without `err_rps` and cannot have an availability SLO measured: its report
  says so. `p95_ms` comes from the access log and is only there in frames
  where the node had requests.

  Requests in a frame are `rps * seconds until the next frame` (at most 2
  minutes, so a gap is not traffic), which weighs a 5 s frame and a minute
  frame by what they stand for. Over a window:

    * availability SLI = 1 - sum(err_rps * s) / sum(rps * s)
    * latency SLI = the requests in frames whose p95 was at most
      `latency_ms`, over the requests in frames that had a p95. This is a
      p95 per frame, not a latency per request: the tape keeps no
      histogram, so "requests served while p95 was under X" is the closest
      it can say.
    * budget left = 1 - (1 - SLI) / (1 - target), as a percentage. Below 0
      the budget is spent and then some.
    * burn rate over a lookback = the error rate over it / (1 - target):
      1x spends the budget exactly over the window.

  ## Burn flags (multiwindow, multi-burn-rate)

  The Google SRE workbook's alerting, chapter 5: page when 2 % of a 30-day
  budget goes in an hour (14.4x over 1 h), ticket when 5 % goes in 6 hours
  (6x over 6 h), each confirmed by a window a twelfth as long (5 m and
  30 m) so a flag stops soon after the burning does. The thresholds are
  the budget shares, not the multipliers: for a 7-day window 2 % in an hour
  is 3.36x and 5 % in 6 hours is 1.4x (`thresholds/1`). A flag also needs
  at least `min_requests` (20) requests in its long lookback: at 0.003
  requests a second one 5xx is a 300x burn, and that is noise.

  ## The tape is shorter than a month

  The tape keeps 7 days (`ObsFactor.Tape`, `keep_ms`). A 30-day window is
  computed over what exists and its report says so in `coverage.note`;
  so is a 7-day window on a tape younger than 7 days.

  ## Running

  The server (`child_specs/1`) evaluates every minute: it computes every
  report, broadcasts them on `ObsFactor.PubSub` topic `"slo"` as
  `{:slo_status, reports}`, and when a burn flag starts it queues a wire
  item (`ObsFactor.Wire`'s shape) of kind `"slo_burn"`, `sev` `"alert"`
  for a fast burn and `"warn"` for a slow one. The ticker takes the queue
  (`drain/0`) into its next tick's wire, so the item is on the tape, in the
  tick's push and on the board like any other. Which flags are burning is
  kept in the row (`burning`), so a restart of the observer does not say
  it again.
  """
  use GenServer
  require Logger

  alias ObsFactor.Tape

  @topic "slo"
  @table :obs_factor_slo_wire
  @max_queued 200
  @every_ms 60_000
  @min_requests 20
  @cap "interval '2 minutes'"

  @ddl """
  CREATE TABLE IF NOT EXISTS slo_targets (
    node text PRIMARY KEY,
    availability double precision NOT NULL,
    latency_ms double precision,
    latency_target double precision,
    window_days integer NOT NULL,
    burning jsonb NOT NULL DEFAULT '{}'::jsonb,
    by text,
    updated_at timestamptz NOT NULL DEFAULT now()
  )
  """

  # lookback name => ms; the long ones flag, the short ones confirm
  @lookbacks %{"5m" => 300_000, "1h" => 3_600_000, "30m" => 1_800_000, "6h" => 21_600_000}
  @flags [fast: {"1h", "5m", 0.02}, slow: {"6h", "30m", 0.05}]

  def topic, do: @topic

  # ---- targets ----------------------------------------------------------------

  @doc "Creates the table if it is not there. `:ok` or `{:error, reason}`."
  def ensure(db \\ Tape.db()) do
    case q(db, @ddl, []) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  @cols "node, availability, latency_ms, latency_target, window_days, burning, by, updated_at"

  @doc "Every target, by node: `{:ok, [target]}`."
  def targets(db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT #{@cols} FROM slo_targets ORDER BY node", []) do
      {:ok, Enum.map(rows, &row/1)}
    end
  end

  @doc """
  Set a node's target (`%{"node", "availability", "window_days",
  "latency_ms", "latency_target", "by"}`), replacing the one it had.
  `{:ok, target}` or `{:error, reason}`.
  """
  def save(attrs, db \\ Tape.db())

  def save(attrs, db) when is_map(attrs) do
    with :ok <- ensure(db),
         {:ok, node} <- node_id(attrs["node"]),
         {:ok, avail} <- fraction(attrs["availability"], "availability"),
         {:ok, days} <- window_days(attrs["window_days"]),
         {:ok, lat_ms, lat_t} <- latency(attrs["latency_ms"], attrs["latency_target"]) do
      by = if is_binary(attrs["by"]), do: String.slice(String.trim(attrs["by"]), 0, 60)

      sql = """
      INSERT INTO slo_targets (node, availability, latency_ms, latency_target, window_days, by)
      VALUES ($1, $2, $3, $4, $5, $6)
      ON CONFLICT (node) DO UPDATE SET availability = $2, latency_ms = $3, latency_target = $4, window_days = $5,
        by = coalesce($6, slo_targets.by), updated_at = now()
      RETURNING #{@cols}
      """

      case q(db, sql, [node, avail, lat_ms, lat_t, days, by]) do
        {:ok, %{rows: [r]}} -> {:ok, row(r)}
        {:error, e} -> {:error, Tape.message(e)}
      end
    end
  end

  def save(other, _), do: {:error, "a target is a map, got #{inspect(other)}"}

  @doc "Remove a node's target. `{:ok, node}` or `{:error, reason}`."
  def delete(node, db \\ Tape.db())

  def delete(node, db) when is_binary(node) do
    with :ok <- ensure(db),
         {:ok, %{num_rows: 1}} <- q(db, "DELETE FROM slo_targets WHERE node = $1", [node]) do
      {:ok, node}
    else
      {:ok, %{num_rows: 0}} -> {:error, "no target for #{node}"}
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  def delete(node, _), do: {:error, "a node id is text, got #{inspect(node)}"}

  defp node_id(n) when is_binary(n) do
    case String.trim(n) do
      "" -> {:error, "a target needs a node id"}
      t when byte_size(t) > 80 -> {:error, "a node id is at most 80 characters"}
      t -> {:ok, t}
    end
  end

  defp node_id(_), do: {:error, "a target needs a node id"}

  # a target share: above 0.5 (anything lower is not an objective) and below 1
  # (a 100 % target has no budget to burn)
  defp fraction(v, _what) when is_number(v) and v > 0.5 and v < 1, do: {:ok, v / 1}
  defp fraction(v, what), do: {:error, "#{what} is a share between 0.5 and 1, e.g. 0.995; got #{inspect(v)}"}

  defp window_days(d) when d in [7, 30], do: {:ok, d}
  defp window_days(nil), do: {:ok, 30}
  defp window_days(d), do: {:error, "window_days is 7 or 30, got #{inspect(d)}"}

  defp latency(nil, _), do: {:ok, nil, nil}
  defp latency(ms, nil) when is_number(ms) and ms > 0, do: {:ok, ms / 1, 0.99}

  defp latency(ms, t) when is_number(ms) and ms > 0 do
    with {:ok, t} <- fraction(t, "latency_target"), do: {:ok, ms / 1, t}
  end

  defp latency(ms, _), do: {:error, "latency_ms is a number of milliseconds above 0, or none; got #{inspect(ms)}"}

  defp row([node, avail, lat_ms, lat_t, days, burning, by, updated]),
    do: %{node: node, availability: avail, latency_ms: lat_ms, latency_target: lat_t, window_days: days, burning: burning || %{}, by: by, updated_at: ms(updated)}

  # ---- measuring ---------------------------------------------------------------

  @doc """
  The burn-rate thresholds for a window of `days`: `%{fast, slow}`, the
  multipliers at which 2 % of the budget goes in 1 h and 5 % in 6 h.
  `%{fast: 14.4, slow: 6.0}` for 30 days.
  """
  def thresholds(days) do
    hours = days * 24
    Map.new(@flags, fn {flag, {long, _, share}} -> {flag, Float.round(share * hours / (@lookbacks[long] / 3_600_000), 3)} end)
  end

  @doc """
  Every target's report at `now_ms`: `{:ok, [report]}` or `{:error, reason}`.
  `opts`: `db`, `nodes` (only these), `min_requests`, `labels` (node =>
  label; the topology's by default).
  """
  def report(now_ms, opts \\ []) do
    db = Keyword.get(opts, :db, Tape.db())

    with {:ok, targets} <- targets(db) do
      targets = if opts[:nodes] in [nil, []], do: targets, else: Enum.filter(targets, &(&1.node in opts[:nodes]))
      measure(targets, now_ms, db, opts)
    end
  end

  @doc false
  def measure([], _now, _db, _opts), do: {:ok, []}

  def measure(targets, now_ms, db, opts) do
    min_req = Keyword.get(opts, :min_requests, @min_requests)
    labels = Keyword.get_lazy(opts, :labels, &labels/0)

    with {:ok, sums} <- sums(targets, now_ms, db),
         {:ok, %{rows: [[oldest]]}} <- q(db, "SELECT min(at) FROM tape_frames", []) do
      {:ok, Enum.map(targets, &one(&1, Map.get(sums, &1.node, %{}), ms(oldest), now_ms, min_req, labels))}
    end
  end

  # per node, per lookback ("window" and @lookbacks): requests, 5xx,
  # requests with a p95, requests while p95 was under the target, the
  # first frame and the seconds of tape. One pass over the frames: each
  # frame's metrics are unpacked once (jsonb_each, only the targets' keys)
  # and every lookback is a FILTER of the same aggregate; reading
  # `metrics->node` per target and joining the lookbacks as rows took 4.8 s
  # for 10 targets over 7 days of production-sized frames
  defp sums(targets, now_ms, db) do
    nodes = Enum.map(targets, & &1.node)
    since = Enum.map(targets, &dt(now_ms - &1.window_days * 86_400_000))
    lat = Enum.map(targets, & &1.latency_ms)
    from = Enum.min(since, DateTime)
    looks = [{"window", nil} | Enum.map(@lookbacks, fn {k, v} -> {k, dt(now_ms - v)} end)]

    cols =
      looks
      |> Enum.with_index(5)
      |> Enum.map_join(",\n", fn {{_, since}, i} ->
        # "window" (index 5) has no parameter: the lookbacks are $6..
        w = if since, do: "e.at >= $#{i}", else: "true"

        """
               sum(e.rps * e.s) FILTER (WHERE #{w} AND e.err IS NOT NULL),
               sum(e.err * e.s) FILTER (WHERE #{w} AND e.err IS NOT NULL),
               sum(e.rps * e.s) FILTER (WHERE #{w} AND e.p95 IS NOT NULL),
               sum(e.rps * e.s) FILTER (WHERE #{w} AND e.p95 <= e.lat),
               min(e.at) FILTER (WHERE #{w}), sum(e.s) FILTER (WHERE #{w}), count(*) FILTER (WHERE #{w} AND e.err IS NOT NULL)\
        """
      end)

    sql = """
    WITH t AS (SELECT * FROM unnest($3::text[], $4::timestamptz[], $5::float8[]) AS t(node, since, lat)),
    f AS (
      SELECT at, metrics,
             extract(epoch FROM greatest(least(coalesce(lead(at) OVER (ORDER BY at), $2) - at, #{@cap}), interval '0'))::float8 AS s
      FROM tape_frames WHERE at >= $1 AND at <= $2
    ),
    x AS (
      SELECT f.at, f.s, x.k, x.v FROM f, jsonb_each(f.metrics) AS x(k, v)
      WHERE f.metrics IS NOT NULL AND x.k = ANY($3) AND jsonb_typeof(x.v->'rps') = 'number'
    ),
    e AS (
      SELECT x.at, x.s, t.node, t.lat, (x.v->>'rps')::float8 AS rps,
             CASE WHEN jsonb_typeof(x.v->'err_rps') = 'number' THEN (x.v->>'err_rps')::float8 END AS err,
             CASE WHEN jsonb_typeof(x.v->'p95_ms') = 'number' THEN (x.v->>'p95_ms')::float8 END AS p95
      FROM x JOIN t ON t.node = x.k AND x.at >= t.since
    )
    SELECT e.node,
    #{cols}
    FROM e GROUP BY e.node
    """

    params = [from, dt(now_ms), nodes, since, lat] ++ for({_, d} <- looks, d, do: d)

    with {:ok, %{rows: rows}} <- q(db, sql, params) do
      {:ok,
       Map.new(rows, fn [node | vals] ->
         {node,
          looks
          |> Enum.zip(Enum.chunk_every(vals, 7))
          |> Map.new(fn {{look, _}, [req, err, lreq, lgood, first, secs, with_err]} ->
            {look, if(first, do: %{req: f(req), err: f(err), lreq: f(lreq), lgood: f(lgood), first: ms(first), secs: f(secs), with_err: with_err})}
          end)}
       end)}
    else
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  defp one(t, s, oldest, now_ms, min_req, labels) do
    window_ms = t.window_days * 86_400_000
    win = s["window"] || %{req: 0.0, err: 0.0, lreq: 0.0, lgood: 0.0, first: nil, secs: 0.0, with_err: 0}
    th = thresholds(t.window_days)

    avail =
      objective(t.availability, th, min_req, fn look ->
        x = s[look]
        if x && x.req > 0, do: {x.err / x.req, x.req, x.err}
      end)

    latency =
      if t.latency_ms do
        objective(t.latency_target, th, min_req, fn look ->
          x = s[look]
          if x && x.lreq > 0, do: {(x.lreq - x.lgood) / x.lreq, x.lreq, x.lreq - x.lgood}
        end)
      end

    %{
      node: t.node,
      label: Map.get(labels, t.node) || t.node,
      window_days: t.window_days,
      target: Map.take(t, [:availability, :latency_ms, :latency_target]),
      by: t.by,
      updated_at: t.updated_at,
      thresholds: th,
      coverage: coverage(window_ms, now_ms, oldest, win),
      availability: avail,
      latency: latency,
      burning: t.burning,
      note: if(win.with_err == 0 and win.secs > 0, do: "#{t.node} has requests on the tape but no 5xx count: it is reached only by path routes, which the proxy does not count per node, so its availability cannot be measured")
    }
  end

  # one objective: SLI and budget over the window, burn per lookback, flags
  defp objective(target, th, min_req, read) do
    budget = 1 - target

    burn =
      Map.new(@lookbacks, fn {k, _} ->
        {k, case read.(k) do
              {rate, _, _} -> Float.round(rate / budget, 3)
              nil -> nil
            end}
      end)

    flags =
      Map.new(@flags, fn {flag, {long, short, _}} ->
        limit = th[flag]

        on =
          case {read.(long), burn[long], burn[short]} do
            {{_, req, _}, b, c} when is_number(b) and is_number(c) -> req >= min_req and b >= limit and c >= limit
            _ -> false
          end

        {flag, on}
      end)

    case read.("window") do
      {rate, req, bad} ->
        %{target: target, sli: 1 - rate, requests: round(req), bad: round(bad), budget_left_pct: Float.round((1 - rate / budget) * 100, 1), burn: burn, fast: flags.fast, slow: flags.slow}

      nil ->
        %{target: target, sli: nil, requests: 0, bad: 0, budget_left_pct: nil, burn: burn, fast: false, slow: false}
    end
  end

  defp coverage(window_ms, now_ms, oldest, win) do
    start = now_ms - window_ms
    covered = if win.first, do: now_ms - max(win.first, start), else: 0

    note =
      cond do
        oldest == nil -> "the tape is empty"
        oldest > start + 60_000 and window_ms > 7 * 86_400_000 ->
          "a #{div(window_ms, 86_400_000)}-day window, but the tape keeps 7 days and begins #{span(now_ms - oldest)} ago: computed over those"
        oldest > start + 60_000 -> "the tape begins #{span(now_ms - oldest)} ago: computed over that, not the whole #{div(window_ms, 86_400_000)} days"
        true -> nil
      end

    %{window_ms: window_ms, from: max(start, oldest || start), to: now_ms, covered_ms: covered, tape_from: oldest, note: note}
  end

  defp span(ms) when ms >= 86_400_000, do: "#{div(ms, 86_400_000)}d #{rem(div(ms, 3_600_000), 24)}h"
  defp span(ms) when ms >= 3_600_000, do: "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"
  defp span(ms), do: "#{div(ms, 60_000)}m"

  defp labels do
    Map.new(ObsFactor.topology().nodes, &{&1.id, &1.label})
  rescue
    _ -> %{}
  end

  # ---- burn flags into the wire ------------------------------------------------

  @doc """
  The flags that started in `reports` and are not yet in their row's
  `burning`, as wire items, and the new `burning` per node: `{items,
  %{node => burning}}` (only nodes whose burning changed).
  """
  def edges(reports, now_ms) do
    Enum.reduce(reports, {[], %{}}, fn r, {items, changed} ->
      on =
        for {obj, o} <- [availability: r.availability, latency: r.latency], o, flag <- [:fast, :slow], Map.get(o, flag),
            into: %{},
            do: {"#{obj}.#{flag}", {obj, flag, o}}

      was = r.burning
      started = for {k, v} <- on, not Map.has_key?(was, k), do: item(r, v, now_ms)
      now = Map.new(on, fn {k, _} -> {k, Map.get(was, k, now_ms)} end)
      {items ++ started, if(now == was, do: changed, else: Map.put(changed, r.node, now))}
    end)
  end

  defp item(r, {obj, flag, o}, now_ms) do
    {long, short, share} = @flags[flag]
    limit = r.thresholds[flag]
    what = if obj == :availability, do: "Target #{pct(o.target)} of requests without a 5xx", else: "Target #{pct(o.target)} of requests while p95 ≤ #{round(r.target.latency_ms)} ms"

    %{
      at: now_ms,
      app: r.node,
      label: r.label,
      member: nil,
      kind: "slo_burn",
      sev: if(flag == :fast, do: "alert", else: "warn"),
      head: "#{if flag == :fast, do: "fast", else: "slow"} burn of the #{obj} budget: #{x(o.burn[long])} over #{long}",
      text:
        "#{what}, #{r.window_days}-day window. Burn #{x(o.burn[long])} over #{long} and #{x(o.burn[short])} over #{short}; " <>
          "flagged at #{limit}x (#{round(share * 100)}% of the budget in #{long}). Budget left: #{if o.budget_left_pct, do: "#{o.budget_left_pct}%", else: "unknown"}."
    }
  end

  defp x(nil), do: "–"
  defp x(v), do: "#{:erlang.float_to_binary(v / 1, decimals: 1)}x"

  @doc false
  def pct(v), do: "#{:erlang.float_to_binary(v * 100, [:compact, decimals: 3])}%"

  @doc """
  The queued `slo_burn` items, taken: the ticker appends them to its tick's
  wire (`ObsFactor.Ticker`). `[]` when there is no SLO server.
  """
  def drain do
    case :ets.whereis(@table) do
      :undefined -> []
      _ -> @table |> :ets.take(:q) |> Enum.flat_map(fn {:q, items} -> items end) |> Enum.sort_by(& &1.at)
    end
  rescue
    ArgumentError -> []
  end

  defp enqueue([]), do: :ok

  defp enqueue(items) do
    # a bag: each evaluation's items under :q; at most @max_queued kept when
    # nothing drains (no ticker running)
    held = :ets.lookup(@table, :q) |> Enum.flat_map(&elem(&1, 1))

    if length(held) + length(items) > @max_queued do
      :ets.delete(@table, :q)
      :ets.insert(@table, {:q, Enum.take(held ++ items, -@max_queued)})
    else
      :ets.insert(@table, {:q, items})
    end

    :ok
  end

  # ---- the server --------------------------------------------------------------

  @doc "The server, when there is an objectives database: `[]` without one."
  def child_specs(nil), do: []
  def child_specs(_url), do: [{__MODULE__, []}]

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Evaluate now (tests, and after a target is saved). Returns the reports."
  def evaluate(server \\ __MODULE__, now_ms \\ nil), do: GenServer.call(server, {:evaluate, now_ms}, 30_000)

  @impl true
  def init(opts) do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:bag, :public, :named_table])

    state = %{
      db: Keyword.get(opts, :db, Tape.db()),
      topic: Keyword.get(opts, :topic, @topic),
      every_ms: Keyword.get(opts, :every_ms, @every_ms),
      min_requests: Keyword.get(opts, :min_requests, @min_requests),
      labels: Keyword.get(opts, :labels),
      logged_at: 0
    }

    if state.every_ms, do: Process.send_after(self(), :evaluate, Keyword.get(opts, :first_after_ms, 30_000))
    {:ok, state}
  end

  @impl true
  def handle_info(:evaluate, state) do
    Process.send_after(self(), :evaluate, state.every_ms)
    {_, state} = run(state, System.system_time(:millisecond))
    {:noreply, state}
  end

  @impl true
  def handle_call({:evaluate, now_ms}, _from, state) do
    {reply, state} = run(state, now_ms || System.system_time(:millisecond))
    {:reply, reply, state}
  end

  defp run(state, now_ms) do
    opts = [db: state.db, min_requests: state.min_requests] ++ if(state.labels, do: [labels: state.labels], else: [])

    with {:ok, reports} <- report(now_ms, opts),
         {items, changed} = edges(reports, now_ms),
         :ok <- keep_burning(state.db, changed) do
      enqueue(items)
      reports = Enum.map(reports, fn r -> Map.update!(r, :burning, &Map.get(changed, r.node, &1)) end)
      Phoenix.PubSub.broadcast(ObsFactor.PubSub, state.topic, {:slo_status, reports})
      {{:ok, reports}, state}
    else
      {:error, e} -> {{:error, Tape.message(e)}, complain(state, e)}
    end
  end

  defp keep_burning(db, changed) do
    Enum.reduce_while(changed, :ok, fn {node, burning}, :ok ->
      case q(db, "UPDATE slo_targets SET burning = $2 WHERE node = $1", [node, burning]) do
        {:ok, _} -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp complain(state, e) do
    now = System.monotonic_time(:millisecond)

    if now - state.logged_at > 600_000 do
      Logger.error("slo: cannot evaluate: #{Tape.message(e)}", event: "slo.failed", reason: Tape.message(e))
      %{state | logged_at: now}
    else
      state
    end
  end

  # ---- the writeup ---------------------------------------------------------------

  @doc """
  The writeup's "SLOs" section (`ObsFactor.Writeup`): every target, as it
  stood at `to_ms`, only `apps` when there are some.
  """
  def writeup(to_ms, apps, db) do
    case report(to_ms, db: db, nodes: apps) do
      {:ok, []} ->
        "## SLOs\n\nNo error budget is set#{if apps != [], do: " for these buildings", else: ""}. Set one on the board's SLO tab."

      {:ok, reports} ->
        rows =
          for r <- reports, {name, o} <- [{"availability", r.availability}, {"latency", r.latency}], o do
            [r.label, name, pct(o.target), sli(o.sli), if(o.budget_left_pct, do: "#{o.budget_left_pct}%"), x(o.burn["1h"]), x(o.burn["6h"]),
             flags(o), o.requests]
          end

        notes =
          for r <- reports, n <- [r.coverage.note, r.note], n, do: "- **#{r.label}**: #{n}"

        "## SLOs\n\nAs they stood at the end of the range, each over its own rolling window. Burn: 1x spends the budget exactly over the window.\n\n" <>
          ObsFactor.Writeup.table(["App", "Objective", "Target", "SLI", "Budget left", "Burn 1 h", "Burn 6 h", "Flags", "Requests"], rows) <>
          if(notes == [], do: "", else: "\n\n" <> Enum.join(notes, "\n"))

      {:error, e} ->
        "## SLOs\n\nCould not be read: #{e}"
    end
  end

  defp sli(nil), do: "no requests"
  defp sli(v), do: "#{:erlang.float_to_binary(v * 100, decimals: 3)}%"

  defp flags(o) do
    case {o.fast, o.slow} do
      {true, true} -> "fast and slow burn"
      {true, _} -> "fast burn"
      {_, true} -> "slow burn"
      _ -> "–"
    end
  end

  # ---- helpers -------------------------------------------------------------------

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp f(nil), do: 0.0
  defp f(%Decimal{} = d), do: Decimal.to_float(d)
  defp f(n), do: n / 1

  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)
end
