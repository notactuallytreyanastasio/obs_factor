defmodule ObsFactor.Evidence do
  @moduledoc """
  Evidence taken at the moment: when the BEAM wire (`ObsFactor.Wire`) says
  something is wrong inside a BEAM, the observer engine is asked, right
  then, what that BEAM is doing. Replay cannot answer that later: the tape
  keeps numbers per node, not which process burned them.

  ## What triggers a capture

  A wire item of kind `outlier`, `anomaly`, `crash`, `restart`, `mailbox`
  or `runq`; a `failing` item about a `db.query` stream; a `surge` of Repo
  queries. Configurable (`config :obs_factor, :evidence, kinds: [...]`,
  where `"failing:db.query"` and `"surge:db.query"` name the Repo cases).

  ## What is captured

  For the BEAM the item is about (a member of a cluster by its address;
  every member, at most #{4}, for an item about the whole app):

    * the engine's top 10 processes by reductions over 500 ms
      (`procs?sort=reductions&interval_ms=500`), by memory and by
      message_queue_len, each with its pid, registered name, initial call,
      current function, status, memory, mailbox and reductions;
    * the engine's 10 biggest ETS tables (`ets`);
    * from the snapshot of that tick: the app's (or the member's) `tables`
      (Repo time per table) and `liveviews`, and the app's last 20 logged
      `events`.

  What could not be read is in `errors`, by name, and the capture is
  stored anyway: evidence that the engine timed out at that moment is
  evidence too. A node without a report has no engine: only the snapshot
  part is kept, and `errors` says so.

  ## Not blocking, not hammering

  `notice/1` is a cast from the ticker; the capture runs in a task. At most
  one capture per BEAM (`{app, address}`) per 60 s (`every_ms`): an item
  inside that minute is linked to the capture already taken (its
  `captured_before_ms` says how long before the item it was taken), not
  captured again.

  ## Where

  `wire_evidence` (one row per capture, the body as jsonb) and
  `wire_evidence_links` (one row per wire item it explains: the
  `tape_wire` id once the tape has written it, and the item's time, app,
  member, kind and headline, so a live item without an id yet is matched
  too), in the objectives database, next to the tape. Kept 7 days. Every
  capture, and every item linked to one later, is broadcast on
  `ObsFactor.PubSub` topic `"evidence"` as `{:evidence, entry}`
  (`index/3`'s shape).
  """
  use GenServer
  require Logger

  alias ObsFactor.Tape

  @topic "evidence"
  @kinds ~w(outlier anomaly crash restart mailbox runq failing:db.query surge:db.query)
  @every_ms 60_000
  @max_members 4
  @top 10
  @keep_ms 7 * 86_400_000
  @proc_keys ~w(pid registered_name initial_call current_function status memory message_queue_len reductions reductions_per_s reductions_delta)
  @sorts [
    {"reductions", %{"sort" => "reductions", "limit" => "#{@top}", "interval_ms" => "500"}},
    {"memory", %{"sort" => "memory", "limit" => "#{@top}"}},
    {"message_queue_len", %{"sort" => "message_queue_len", "limit" => "#{@top}"}}
  ]

  @ddl [
    """
    CREATE TABLE IF NOT EXISTS wire_evidence (
      id bigserial PRIMARY KEY,
      at timestamptz NOT NULL,
      app text NOT NULL,
      member text,
      address text,
      body jsonb NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS wire_evidence_at ON wire_evidence (at)",
    """
    CREATE TABLE IF NOT EXISTS wire_evidence_links (
      evidence_id bigint NOT NULL REFERENCES wire_evidence (id) ON DELETE CASCADE,
      wire_id bigint,
      at timestamptz NOT NULL,
      app text,
      member text,
      kind text NOT NULL,
      head text NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS wire_evidence_links_at ON wire_evidence_links (at)",
    "CREATE INDEX IF NOT EXISTS wire_evidence_links_wire ON wire_evidence_links (wire_id)"
  ]

  def topic, do: @topic

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Is there an evidence taker in this observer (and a tape to store into)?"
  def enabled?(server \\ __MODULE__), do: GenServer.whereis(server) != nil and Tape.enabled?()

  @doc """
  The ticker's wire items of one tick. Never blocks: a cast, and nothing
  at all when there is no evidence taker or no tape.
  """
  def notice(items, server \\ __MODULE__) do
    if items != [] and GenServer.whereis(server) != nil and Tape.enabled?(),
      do: GenServer.cast(server, {:notice, items})

    :ok
  end

  @doc "Does this wire item call for evidence?"
  def trigger?(item, kinds \\ @kinds)
  def trigger?(%{kind: "failing", head: "db.query " <> _}, kinds), do: "failing:db.query" in kinds
  def trigger?(%{kind: "surge", head: "Repo queries " <> _}, kinds), do: "surge:db.query" in kinds
  def trigger?(%{kind: k}, kinds) when k not in ["failing", "surge"], do: k in kinds
  def trigger?(_, _), do: false

  @doc """
  Which BEAMs a wire item is about, read off the snapshot (decoded JSON):
  `[%{app, member, address, node}]`, `node` the snapshot's node (nil when
  the app is not on it). A member named by its Erlang node is found by its
  `cluster.node`; an item about the whole app (no member), or about a
  scaled service whose members are not distributed (every one of them is
  the app's id on the wire), is about every member that answered, at most
  #{@max_members}.
  """
  def targets(item, snap) do
    node = Enum.find(snap["nodes"] || [], &(&1["id"] == item.app))
    inside = node && node["inside"]
    members = for m <- (is_map(inside) && inside["members"]) || [], m["ok"] == true, is_binary(m["address"]), do: m
    named = item.member && Enum.find(members, &(get_in(&1, ["cluster", "node"]) == item.member))

    cond do
      named -> [%{app: item.app, member: item.member, address: named["address"], node: node}]
      members == [] -> [%{app: item.app, member: item.member, address: nil, node: node}]
      true -> members |> Enum.take(@max_members) |> Enum.map(&%{app: item.app, member: get_in(&1, ["cluster", "node"]), address: &1["address"], node: node})
    end
  end

  # ---- capturing (in a task) ----------------------------------------------

  @doc """
  One capture: the engine's procs and ETS for the target, and the
  snapshot's tables, liveviews and events. `proxy` answers
  `call("GET", id, path, params, member: address)` as
  `ObsFactor.ObserverProxy` does. Returns the body (string keys).
  """
  def capture(target, proxy \\ ObsFactor.ObserverProxy) do
    started = System.monotonic_time(:millisecond)
    node = target.node || %{}
    inside = node["inside"]
    member = if target.address, do: Enum.find(inside["members"] || [], &(&1["address"] == target.address))
    part = member || inside || %{}

    {procs, ets, errors} =
      if is_map(inside) do
        engine(target, proxy)
      else
        {%{}, [], ["#{target.app} has no report, so no observer engine: only the snapshot was kept"]}
      end

    %{
      "app" => target.app,
      "member" => target.member,
      "address" => target.address,
      "procs" => procs,
      "ets" => ets,
      "tables" => part["tables"] || (inside && inside["tables"]) || [],
      "liveviews" => part["liveviews"] || (inside && inside["liveviews"]),
      "events" => ((is_map(inside) && inside["events"]) || []) |> Enum.take(20),
      "errors" => errors,
      "took_ms" => System.monotonic_time(:millisecond) - started
    }
  end

  defp engine(target, proxy) do
    {[hot], rest} = @sorts |> Enum.map(fn {name, params} -> {name, ["procs"], params} end) |> Enum.split_with(&(elem(&1, 0) == "reductions"))
    rest = rest ++ [{"ets", ["ets"], %{}}]

    # memory, mailboxes and ETS first, side by side; the 500 ms reductions
    # window after them, alone. Run beside it, the other reads showed up in
    # its own top 10 (on this VM, in-process: Task.Supervised.stream_reduce/7
    # at 1,148/s). The read itself always does (FactoryReport.Observer.summary/2,
    # about 3,000/s, the walker sampling every process twice): noise beside
    # the millions an outlier means, but not nothing on an idle node.
    results =
      rest
      |> Task.async_stream(fn {_, path, params} -> safe_call(proxy, target, path, params) end,
        timeout: 8_000,
        on_timeout: :kill_task,
        max_concurrency: 3
      )
      |> Enum.zip(rest)

    {_, path, params} = hot
    results = [{{:ok, safe_call(proxy, target, path, params)}, hot} | results]

    Enum.reduce(results, {%{}, [], []}, fn
      {{:ok, {200, %{"procs" => rows}}}, {name, _, _}}, {p, e, errs} ->
        {Map.put(p, name, Enum.map(rows, &Map.take(&1, @proc_keys))), e, errs}

      {{:ok, {200, %{"tables" => rows}}}, {"ets", _, _}}, {p, _, errs} ->
        {p, Enum.take(rows, @top), errs}

      {{:ok, {status, body}}, {name, path, _}}, {p, e, errs} ->
        why = (is_map(body) && body["error"]) || "status #{status}"
        {p, e, errs ++ ["#{Enum.join(path, "/")}#{if name != "ets", do: " by #{name}", else: ""}: #{why}"]}

      {{:exit, reason}, {name, path, _}}, {p, e, errs} ->
        {p, e, errs ++ ["#{Enum.join(path, "/")}#{if name != "ets", do: " by #{name}", else: ""}: no answer in 8 s (#{inspect(reason)})"]}
    end)
  end

  defp safe_call(proxy, target, path, params) do
    case proxy.call("GET", target.app, path, params, member: target.address) do
      {status, body} when is_integer(status) -> {status, body}
      other -> {0, %{"error" => "unexpected answer #{inspect(other, limit: 5)}"}}
    end
  rescue
    e -> {0, %{"error" => Exception.message(e)}}
  catch
    :exit, reason -> {0, %{"error" => "exit #{inspect(reason, limit: 5)}"}}
  end

  # ---- reading (in the caller, through the pool) --------------------------

  @doc """
  The captures linked to wire items in `[from, to]`, newest first, at most
  `limit`, without their bodies:
  `[%{id, at, app, member, address, hot, links: [%{wire_id, at, app, member, kind}]}]`
  (`hot`: the hottest process's name and reductions/s, for a badge).
  """
  def index(from_ms, to_ms, limit \\ 500, db \\ Tape.db()) do
    sql = """
    SELECT e.id, e.at, e.app, e.member, e.address, e.body->'procs'->'reductions'->0,
           json_agg(json_build_array(l.wire_id, (extract(epoch FROM l.at) * 1000)::bigint, l.app, l.member, l.kind, l.head) ORDER BY l.at)
    FROM wire_evidence e JOIN wire_evidence_links l ON l.evidence_id = e.id
    WHERE e.id IN (SELECT evidence_id FROM wire_evidence_links WHERE at >= $1 AND at <= $2)
    GROUP BY e.id ORDER BY e.at DESC LIMIT $3
    """

    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, sql, [dt(from_ms), dt(to_ms), limit]) do
      {:ok, Enum.map(rows, &entry/1)}
    end
  end

  @doc "One capture whole: `{:ok, %{id, at, app, member, address, body, links}}`, `:none` or `{:error, reason}`."
  def get(id, db \\ Tape.db())

  def get(id, db) when is_integer(id) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT body FROM wire_evidence WHERE id = $1", [id]),
         [[body]] <- rows,
         {:ok, [e]} <- entries(db, "e.id = $1", [id]) do
      {:ok, Map.put(e, :body, body)}
    else
      [] -> :none
      {:ok, []} -> :none
      {:error, _} = e -> e
    end
  end

  def get(id, _), do: {:error, "an evidence id is an integer, got #{inspect(id)}"}

  @doc "The capture linked to one tape_wire id, as `get/2`."
  def for_wire(wire_id, db \\ Tape.db())

  def for_wire(wire_id, db) when is_integer(wire_id) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT evidence_id FROM wire_evidence_links WHERE wire_id = $1 ORDER BY evidence_id DESC LIMIT 1", [wire_id]) do
      case rows do
        [[id]] -> get(id, db)
        [] -> :none
      end
    end
  end

  def for_wire(id, _), do: {:error, "a wire id is an integer, got #{inspect(id)}"}

  @doc """
  For the writeup: `%{wire_id => %{at, member, address, procs}}` for the
  wire items in `[from, to]` that have evidence (the newest 300 captures;
  only the processes of each body are read).
  """
  def by_wire(from_ms, to_ms, db \\ Tape.db()) do
    sql = """
    SELECT l.wire_id, e.at, e.member, e.address, e.body->'procs'
    FROM wire_evidence_links l JOIN wire_evidence e ON e.id = l.evidence_id
    WHERE l.at >= $1 AND l.at <= $2 AND l.wire_id IS NOT NULL
      AND e.id IN (SELECT id FROM wire_evidence WHERE at >= $1 - interval '2 minutes' AND at <= $2 + interval '2 minutes' ORDER BY at DESC LIMIT 300)
    """

    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, sql, [dt(from_ms), dt(to_ms)]) do
      {:ok, Map.new(rows, fn [wid, at, member, address, procs] -> {wid, %{at: ms(at), member: member, address: address, procs: procs || %{}}} end)}
    end
  end

  defp entries(db, where, params) do
    sql = """
    SELECT e.id, e.at, e.app, e.member, e.address, e.body->'procs'->'reductions'->0,
           json_agg(json_build_array(l.wire_id, (extract(epoch FROM l.at) * 1000)::bigint, l.app, l.member, l.kind, l.head) ORDER BY l.at)
    FROM wire_evidence e JOIN wire_evidence_links l ON l.evidence_id = e.id
    WHERE #{where} GROUP BY e.id
    """

    with {:ok, %{rows: rows}} <- q(db, sql, params), do: {:ok, Enum.map(rows, &entry/1)}
  end

  defp entry([id, at, app, member, address, hot, links]) do
    at = ms(at)

    %{
      id: id,
      at: at,
      app: app,
      member: member,
      address: address,
      hot: hot && %{name: hot["registered_name"] || hot["initial_call"] || hot["pid"], reductions_per_s: hot["reductions_per_s"]},
      links:
        for [wid, lat, lapp, lmember, kind, head] <- links do
          %{wire_id: wid, at: lat, app: lapp, member: lmember, kind: kind, head: head, captured_before_ms: max(lat - at, 0)}
        end
    }
  end

  @doc "Creates the tables if they are not there. `:ok` or `{:error, reason}`."
  def ensure(db \\ Tape.db()) do
    Enum.reduce_while(@ddl, :ok, fn sql, :ok ->
      case q(db, sql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, e} -> {:halt, {:error, Tape.message(e)}}
      end
    end)
  end

  # ---- the server ----------------------------------------------------------

  @impl true
  def init(opts) do
    cfg = Application.get_env(:obs_factor, :evidence, [])

    state = %{
      db: Keyword.get(opts, :db, Tape.db()),
      topic: Keyword.get(opts, :topic, @topic),
      proxy: Keyword.get(opts, :proxy, ObsFactor.ObserverProxy),
      snapshot: Keyword.get(opts, :snapshot, &latest_snapshot/0),
      kinds: Keyword.get(opts, :kinds, cfg[:kinds] || @kinds),
      every_ms: Keyword.get(opts, :every_ms, cfg[:every_ms] || @every_ms),
      # {app, address} => %{since (monotonic ms), id | nil, pending: [item], at (unix ms)}
      last: %{},
      logged_at: nil
    }

    Process.send_after(self(), :thin, Keyword.get(opts, :thin_first_ms, 300_000))
    {:ok, state}
  end

  @impl true
  def handle_cast({:notice, items}, state) do
    case Enum.filter(items, &trigger?(&1, state.kinds)) do
      [] -> {:noreply, state}
      hits -> {:noreply, take(hits, state)}
    end
  end

  @impl true
  def handle_info({:captured, key, at_ms, body}, state) do
    case Map.get(state.last, key) do
      %{id: nil, pending: items} = slot ->
        case store(state.db, at_ms, key, body, items) do
          {:ok, id} ->
            broadcast(state, id)
            {:noreply, put_in(state.last[key], %{slot | id: id, pending: []})}

          {:error, e} ->
            {:noreply, complain(state, "evidence: a capture was not stored", e)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:resolve, state) do
    _ = resolve(state.db)
    {:noreply, state}
  end

  def handle_info(:thin, state) do
    Process.send_after(self(), :thin, 3_600_000)
    now = System.system_time(:millisecond)
    _ = q(state.db, "DELETE FROM wire_evidence WHERE at < $1", [dt(now - @keep_ms)])
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # each hit, by the BEAMs it is about: a capture, or a link to the one
  # taken less than every_ms ago
  defp take(hits, state) do
    snap = state.snapshot.()
    now = System.monotonic_time(:millisecond)

    hits
    |> Enum.flat_map(fn i -> for t <- targets(i, snap), do: {t, i} end)
    |> Enum.group_by(fn {t, _} -> {t.app, t.address} end)
    |> Enum.reduce(state, fn {key, pairs}, st ->
      items = Enum.map(pairs, &elem(&1, 1))
      {target, _} = hd(pairs)

      case Map.get(st.last, key) do
        %{since: since} = slot when now - since < st.every_ms ->
          if slot.id, do: link_later(st, slot.id, items), else: put_in(st.last[key], %{slot | pending: slot.pending ++ items})

        _ ->
          start_capture(st, key, target)
          put_in(st.last[key], %{since: now, id: nil, pending: items})
      end
    end)
    |> forget_old(now)
  end

  defp forget_old(state, now),
    do: %{state | last: Map.reject(state.last, fn {_, s} -> now - s.since > state.every_ms * 10 end)}

  defp start_capture(state, key, target) do
    me = self()
    proxy = state.proxy

    Task.start(fn ->
      at = System.system_time(:millisecond)

      body =
        try do
          capture(target, proxy)
        rescue
          e -> %{"app" => target.app, "member" => target.member, "address" => target.address, "errors" => ["the capture raised: " <> Exception.message(e)]}
        end

      send(me, {:captured, key, at, body})
    end)
  end

  defp link_later(state, id, items) do
    case insert_links(state.db, id, items) do
      {:ok, _} ->
        broadcast(state, id)
        state

      {:error, e} ->
        complain(state, "evidence: items were not linked", e)
    end
  end

  defp store(db, at_ms, {app, address}, body, items) do
    with :ok <- ensure(db),
         {:ok, %{rows: [[id]]}} <-
           q(db, "INSERT INTO wire_evidence (at, app, member, address, body) VALUES ($1, $2, $3, $4, $5) RETURNING id",
             [dt(at_ms), app, body["member"], address, body]),
         {:ok, _} <- insert_links(db, id, items) do
      {:ok, id}
    end
  end

  # the tape writes its wire rows in its own cast: usually done by now (a
  # capture takes 500 ms at least); what is not is resolved once more later
  defp insert_links(db, id, items) do
    rows = for i <- items, do: [id, dt(i.at), i.app, i.member, i.kind, i.head]

    values =
      for k <- 0..(length(rows) - 1), do: "(" <> Enum.map_join(1..6, ", ", &"$#{k * 6 + &1}") <> ")"

    sql = "INSERT INTO wire_evidence_links (evidence_id, at, app, member, kind, head) VALUES #{Enum.join(values, ", ")}"

    with {:ok, r} <- q(db, sql, List.flatten(rows)) do
      if resolve(db) != {:ok, length(rows)}, do: Process.send_after(self(), :resolve, 5_000)
      {:ok, r}
    end
  end

  @doc false
  # links without a tape_wire id get the id of the item they name
  def resolve(db) do
    sql = """
    UPDATE wire_evidence_links l SET wire_id = w.id FROM tape_wire w
    WHERE l.wire_id IS NULL AND w.at = l.at AND w.kind = l.kind AND w.head = l.head
      AND w.app IS NOT DISTINCT FROM l.app AND w.member IS NOT DISTINCT FROM l.member
    """

    case q(db, sql, []) do
      {:ok, %{num_rows: n}} -> {:ok, n}
      e -> e
    end
  end

  defp broadcast(state, id) do
    case entries(state.db, "e.id = $1", [id]) do
      {:ok, [e]} -> Phoenix.PubSub.broadcast(ObsFactor.PubSub, state.topic, {:evidence, e})
      _ -> :ok
    end
  end

  defp latest_snapshot do
    case ObsFactor.Store.snapshot() do
      {:ok, json} -> Jason.decode!(json)
      _ -> %{"nodes" => []}
    end
  rescue
    _ -> %{"nodes" => []}
  end

  defp complain(state, what, e) do
    now = System.monotonic_time(:millisecond)

    if state.logged_at == nil or now - state.logged_at > 60_000 do
      Logger.error("#{what}: #{Tape.message(e)}", event: "evidence.failed", reason: Tape.message(e))
      %{state | logged_at: now}
    else
      state
    end
  end

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  rescue
    # a value Postgrex cannot encode: an error to log, not a crash
    e in DBConnection.EncodeError -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)
end
