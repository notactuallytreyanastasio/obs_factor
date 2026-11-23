defmodule ObsFactor.Objectives do
  @moduledoc """
  Mission objectives: the things on the floor someone should look at, kept
  until a person has. The attention strip is recomputed every tick and
  forgets; this remembers that something was seen, by whom it was looked
  at, and that it was crossed off, with a note.

  Where they come from:

    * every alert and warning in a snapshot's `attention` (the rules,
      including what a cluster's nodes say about each other);
    * pins: someone on the floor flags a building ("this looks wrong").

  ## The life of one

      open ──look──▶ looking ──cross off──▶ done
        │               │
        └── gone 60 s ──┴──▶ cleared ──cross off──▶ done
                                  │
                                  └── back again ──▶ open (seen_count + 1)

  An objective from a rule is identified by its `key`: the node and the
  text with every number blanked, so "disk 96% full" and "disk 97% full"
  are one objective, not two. One undone objective per key (a partial
  unique index). `cleared` is not `done`: it went away by itself and nobody
  checked, and the debrief says so. A pin never clears itself.

  ## Storage

  Postgres, its own database and role (deploy/objectives-db.sql), through a
  pool of two. The schema is created at start (CREATE ... IF NOT EXISTS).
  The live rows are held here too: a tick touches the database only when
  something changes state, and `last_seen_at` is written at most every
  30 s per row. If Postgres is unreachable the observer runs on, the
  error is logged once per minute, and the API answers 503 with it.

  ## Live

  Every change is broadcast on `ObsFactor.PubSub` topic `"objectives"`
  (option `:topic`) as `{:objective, row}`, the same public row `list/0`
  returns, with its events: a new one, one that came back or cleared
  itself, a pin, a look / done / reopen, and the `last_seen_at` write that
  happens at most every 30 s while a rule still sees it.

  The store's own state goes out on the same topic: `{:objectives_error,
  reason}` when a query starts failing (or fails for another reason), and
  `{:objectives_list, list}` with the whole `list/0` once it answers again.
  The store is probed with `SELECT 1` every 5 s (option `:probe_ms`), so a
  Postgres that goes away while nothing changes is still noticed.
  """
  use GenServer
  require Logger

  @db ObsFactor.ObjectivesDB
  @grace_ms 60_000
  @flush_ms 30_000
  @recent_hours 24

  @ddl [
    """
    CREATE TABLE IF NOT EXISTS objectives (
      id bigserial PRIMARY KEY,
      key text NOT NULL,
      source text NOT NULL,
      node text,
      severity text NOT NULL,
      title text NOT NULL,
      first_text text NOT NULL,
      state text NOT NULL,
      opened_at timestamptz NOT NULL,
      last_seen_at timestamptz NOT NULL,
      cleared_at timestamptz,
      done_at timestamptz,
      done_by text,
      looking_by text,
      note text,
      seen_count integer NOT NULL DEFAULT 1,
      evidence jsonb
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS objectives_one_undone_per_key ON objectives (key) WHERE state <> 'done'",
    "CREATE INDEX IF NOT EXISTS objectives_recent ON objectives (done_at) WHERE state = 'done'",
    """
    CREATE TABLE IF NOT EXISTS objective_events (
      id bigserial PRIMARY KEY,
      objective_id bigint NOT NULL REFERENCES objectives ON DELETE CASCADE,
      at timestamptz NOT NULL,
      kind text NOT NULL,
      by text,
      note text
    )
    """,
    "CREATE INDEX IF NOT EXISTS objective_events_of ON objective_events (objective_id, at)"
  ]

  @columns "id, key, source, node, severity, title, first_text, state, opened_at, last_seen_at, cleared_at, done_at, done_by, looking_by, note, seen_count, evidence"

  # ---- running it --------------------------------------------------------

  @doc "The pool and the server for a postgres:// URL; nothing when it is nil."
  def child_specs(nil), do: []

  def child_specs(url) do
    [
      Supervisor.child_spec(
        {Postgrex,
         ObsFactor.Postgres.opts(url,
           name: @db,
           pool_size: 2,
           statement_timeout: "5000",
           application_name: "obs_factor objectives"
         )},
        id: @db
      ),
      {__MODULE__, db: @db}
    ]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Is there an objectives store in this observer?"
  def enabled?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  # ---- the client side ---------------------------------------------------

  @doc """
  One tick's `attention` (maps with `node`, `severity`, `text`) and, per node
  id, what it looked like (kept as the evidence of a new objective).
  Asynchronous: the ticker never waits on Postgres.
  """
  def observe(attention, nodes, server \\ __MODULE__) do
    if enabled?(server), do: GenServer.cast(server, {:observe, attention, nodes, now_ms()})
    :ok
  end

  @doc "Undone objectives, and those done in the last 24 h, newest first."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "A pin: `%{node, title, note, by}`. Returns `{:ok, objective}`."
  def pin(attrs, server \\ __MODULE__), do: GenServer.call(server, {:pin, attrs})

  @doc """
  Something a person did: `look` (I'm on it), `done` (crossed off, with a
  note), `reopen`. Returns `{:ok, objective}` or `{:error, reason}`.
  """
  def act(id, action, attrs, server \\ __MODULE__) when action in ~w(look done reopen),
    do: GenServer.call(server, {:act, id, action, attrs})

  @doc "The identity of what a rule said: the node and the text, numbers blanked."
  def key(node, text), do: "#{node || "-"}|" <> Regex.replace(~r/\d+(?:[.,]\d+)?/, text, "#")

  # ---- the server --------------------------------------------------------

  @impl true
  def init(opts) do
    db = Keyword.fetch!(opts, :db)
    topic = Keyword.get(opts, :topic, "objectives")
    probe_ms = Keyword.get(opts, :probe_ms, 5_000)
    {:ok, %{db: db, topic: topic, probe_ms: probe_ms, live: %{}, ready: false, error: nil, logged_at: 0}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    Process.send_after(self(), :probe, state.probe_ms)
    {:noreply, start(state)}
  end

  # A Postgres that goes away while nothing changes is noticed here, and one
  # that comes back too.
  @impl true
  def handle_info(:probe, state) do
    Process.send_after(self(), :probe, state.probe_ms)

    state =
      if state.ready do
        case query(state.db, "SELECT 1", []) do
          {:ok, _} -> recovered(state)
          {:error, e} -> failed(state, e)
        end
      else
        start(state)
      end

    {:noreply, state}
  end

  # The schema, then every undone row into memory. Retried on the next tick
  # while Postgres is not there.
  defp start(state) do
    with :ok <- Enum.reduce_while(@ddl, :ok, fn sql, :ok -> step(query(state.db, sql, [])) end),
         {:ok, rows} <- select(state.db, "WHERE state <> 'done'", []) do
      now = now_ms()
      rows |> Enum.reduce(%{state | ready: true, live: %{}}, &put_live(&2, &1, now)) |> recovered()
    else
      {:error, reason} -> failed(state, reason)
    end
  end

  defp step({:ok, _}), do: {:cont, :ok}
  defp step({:error, e}), do: {:halt, {:error, e}}

  @impl true
  def handle_cast({:observe, attention, nodes, now}, %{ready: false} = state) do
    state = start(state)
    if state.ready, do: handle_cast({:observe, attention, nodes, now}, state), else: {:noreply, state}
  end

  def handle_cast({:observe, attention, nodes, now}, state) do
    seen = Map.new(attention, fn a -> {key(a.node, a.text), a} end)

    state =
      Enum.reduce(seen, state, fn {key, a}, st ->
        case st.live[key] do
          nil -> open_new(st, key, a, nodes[a.node], now)
          %{state: "cleared"} = row -> came_back(st, row, a, now)
          row -> still_there(st, row, a, now)
        end
      end)

    state =
      Enum.reduce(state.live, state, fn {key, row}, st ->
        if row.source == "rule" and row.state in ["open", "looking"] and not Map.has_key?(seen, key) and
             now - row.last_seen_ms > @grace_ms do
          cleared(st, row, now)
        else
          st
        end
      end)

    {:noreply, state}
  end

  @impl true
  def handle_call(_msg, _from, %{ready: false} = state) do
    state = start(state)
    if state.ready, do: {:reply, {:error, "starting, try again"}, state}, else: {:reply, {:error, state.error}, state}
  end

  def handle_call(:list, _from, state) do
    case read_list(state) do
      {:ok, _} = ok -> {:reply, ok, recovered(state)}
      {:error, e} = err -> {:reply, err, failed(state, e)}
    end
  end

  def handle_call({:pin, attrs}, _from, state) do
    now = now_ms()
    key = "pin:" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
    title = clip(attrs["title"]) || "flagged on the floor"
    a = %{node: clip(attrs["node"]), severity: "warn", text: title}

    case insert(state.db, key, "pin", a, nil, now) do
      {:ok, row} ->
        event(state.db, row.id, "pinned", clip(attrs["by"]), clip(attrs["note"], 1000))
        row = if n = clip(attrs["note"], 1000), do: update!(state.db, row.id, "note = $2", [n]), else: row
        announce(state, row)
        {:reply, {:ok, public(row)}, state |> put_live(row, now) |> recovered()}

      {:error, e} ->
        {:reply, {:error, message(e)}, state}
    end
  end

  def handle_call({:act, id, action, attrs}, _from, state) do
    by = clip(attrs["by"])
    note = clip(attrs["note"], 1000)

    result =
      with {:ok, [row]} <- select(state.db, "WHERE id = $1", [id]) |> found() do
        case {action, row.state} do
          {"look", s} when s in ["open", "cleared"] ->
            set(state.db, row, "state = 'looking', looking_by = $2", [by], "looking", by, note)

          {"look", "looking"} ->
            set(state.db, row, "looking_by = $2", [by], "looking", by, note)

          {"done", s} when s != "done" ->
            set(state.db, row, "state = 'done', done_at = now(), done_by = $2, note = coalesce($3, note)", [by, note], "crossed off", by, note)

          {"reopen", "done"} ->
            # a key can have only one undone row: reopening yields to a newer one
            if Enum.any?(Map.values(state.live), &(&1.key == row.key)),
              do: {:error, "this came back since and is open as a newer objective"},
              else: set(state.db, row, "state = 'open', done_at = NULL, done_by = NULL", [], "reopened", by, note)

          {_, s} ->
            {:error, "cannot #{action} an objective that is #{s}"}
        end
      end

    case result do
      {:ok, row} ->
        announce(state, row)
        {:reply, {:ok, public(row)}, state |> sync_live(row) |> recovered()}

      {:error, e} -> {:reply, {:error, message(e)}, state}
    end
  end

  defp read_list(state) do
    with {:ok, undone} <- select(state.db, "WHERE state <> 'done'", []),
         {:ok, done} <-
           select(state.db, "WHERE state = 'done' AND done_at > now() - make_interval(hours => $1)", [@recent_hours]),
         ids = Enum.map(undone ++ done, & &1.id),
         {:ok, events} <- events(state.db, ids) do
      # what is in memory is newer than the database for last_seen
      undone = Enum.map(undone, fn r -> %{r | last_seen_at: last_seen(state, r)} end)
      {:ok, Enum.map(undone ++ done, &Map.put(public(&1), :events, Map.get(events, &1.id, [])))}
    end
  end

  # ---- the transitions ---------------------------------------------------

  defp open_new(st, key, a, evidence, now) do
    case insert(st.db, key, "rule", a, evidence, now) do
      {:ok, row} ->
        event(st.db, row.id, "seen", nil, a.text)
        announce(st, row)
        put_live(st, row, now)

      {:error, e} ->
        failed(st, e)
    end
  end

  defp came_back(st, row, a, now) do
    case update(st.db, row.id, "state = 'open', cleared_at = NULL, seen_count = seen_count + 1, title = $2, last_seen_at = $3",
           [a.text, ms_to_dt(now)]) do
      {:ok, row} ->
        event(st.db, row.id, "came back", nil, a.text)
        announce(st, row)
        put_live(st, row, now)

      {:error, e} ->
        failed(st, e)
    end
  end

  defp still_there(st, row, a, now) do
    row = %{row | last_seen_ms: now, title: a.text}

    if now - row.flushed_ms >= @flush_ms do
      case update(st.db, row.id, "last_seen_at = $2, title = $3", [ms_to_dt(now), a.text]) do
        {:ok, written} ->
          announce(st, written)
          %{st | live: Map.put(st.live, row.key, %{row | flushed_ms: now})}

        {:error, e} -> failed(%{st | live: Map.put(st.live, row.key, row)}, e)
      end
    else
      %{st | live: Map.put(st.live, row.key, row)}
    end
  end

  defp cleared(st, row, now) do
    case update(st.db, row.id, "state = 'cleared', cleared_at = $2, last_seen_at = $3",
           [ms_to_dt(now), ms_to_dt(row.last_seen_ms)]) do
      {:ok, row} ->
        event(st.db, row.id, "cleared itself", nil, nil)
        announce(st, row)
        put_live(st, row, now)

      {:error, e} ->
        failed(st, e)
    end
  end

  defp set(db, row, sql, params, kind, by, note) do
    with {:ok, row} <- update(db, row.id, sql, params) do
      event(db, row.id, kind, by, note)
      {:ok, row}
    end
  end

  defp put_live(st, row, now) do
    %{st | live: Map.put(st.live, row.key, Map.merge(row, %{last_seen_ms: dt_to_ms(row.last_seen_at), flushed_ms: now}))}
  end

  defp sync_live(st, %{state: "done"} = row), do: %{st | live: Map.delete(st.live, row.key)}
  defp sync_live(st, row), do: put_live(st, row, now_ms())

  defp last_seen(st, r) do
    case st.live[r.key] do
      %{last_seen_ms: ms} -> ms_to_dt(ms)
      _ -> r.last_seen_at
    end
  end

  # The row as list/0 shows it, with its events, to everyone on the topic.
  # A failed events read still announces the change, with the reason.
  defp announce(st, row) do
    pub =
      case events(st.db, [row.id]) do
        {:ok, evs} -> Map.put(public(row), :events, Map.get(evs, row.id, []))
        {:error, e} -> public(row) |> Map.put(:events, []) |> Map.put(:events_error, message(e))
      end

    Phoenix.PubSub.broadcast(ObsFactor.PubSub, st.topic, {:objective, pub})
  end

  # ---- SQL ---------------------------------------------------------------

  defp insert(db, key, source, a, evidence, now) do
    t = ms_to_dt(now)

    db
    |> query(
      "INSERT INTO objectives (key, source, node, severity, title, first_text, state, opened_at, last_seen_at, evidence) " <>
        "VALUES ($1, $2, $3, $4, $5, $5, 'open', $6, $6, $7) RETURNING #{@columns}",
      [key, source, a.node, a.severity, a.text, t, evidence && Map.take(evidence, [:label, :status, :reason, :headline])]
    )
    |> one()
  end

  defp update(db, id, set, params) do
    db |> query("UPDATE objectives SET #{set} WHERE id = $1 RETURNING #{@columns}", [id | params]) |> one()
  end

  defp update!(db, id, set, params) do
    {:ok, row} = update(db, id, set, params)
    row
  end

  defp select(db, where, params) do
    case query(db, "SELECT #{@columns} FROM objectives #{where} ORDER BY opened_at DESC, id DESC", params) do
      {:ok, r} -> {:ok, rows(r)}
      e -> e
    end
  end

  defp found({:ok, []}), do: {:error, "no such objective"}
  defp found(other), do: other

  defp event(db, id, kind, by, note) do
    query(db, "INSERT INTO objective_events (objective_id, at, kind, by, note) VALUES ($1, now(), $2, $3, $4)", [id, kind, by, note])
  end

  defp events(_db, []), do: {:ok, %{}}

  defp events(db, ids) do
    case query(db, "SELECT objective_id, at, kind, by, note FROM objective_events WHERE objective_id = ANY($1) ORDER BY at, id", [ids]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         rows
         |> Enum.group_by(&hd/1, fn [_, at, kind, by, note] -> %{at: iso(at), kind: kind, by: by, note: note} end)
         |> Map.new(fn {id, evs} -> {id, Enum.take(evs, -20)} end)}

      e ->
        e
    end
  end

  defp query(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp one({:ok, r}), do: {:ok, r |> rows() |> hd()}
  defp one(e), do: e

  defp rows(%Postgrex.Result{columns: cols, rows: rows}) do
    keys = Enum.map(cols, &String.to_existing_atom/1)
    Enum.map(rows, fn r -> Map.new(Enum.zip(keys, r)) end)
  end

  defp public(row) do
    row
    |> Map.drop([:last_seen_ms, :flushed_ms])
    |> Map.new(fn
      {k, %DateTime{} = v} -> {k, iso(v)}
      kv -> kv
    end)
  end

  # ---- small things ------------------------------------------------------

  # The store's state on the topic: the first failure (or a different one)
  # as {:objectives_error, msg}, the first success after it as the whole list.
  defp failed(state, reason) do
    msg = message(reason)
    now = now_ms()

    if msg != state.error, do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, state.topic, {:objectives_error, msg})

    if now - state.logged_at > 60_000 do
      Logger.error("objectives: #{msg}", source: "objectives")
      %{state | error: msg, logged_at: now}
    else
      %{state | error: msg}
    end
  end

  defp recovered(%{error: nil} = state), do: state

  defp recovered(state) do
    case read_list(state) do
      {:ok, list} ->
        Logger.info("objectives: the store answers again (it had failed: #{state.error})", source: "objectives")
        Phoenix.PubSub.broadcast(ObsFactor.PubSub, state.topic, {:objectives_list, list})
        %{state | error: nil}

      {:error, e} ->
        failed(state, e)
    end
  end

  defp message(%{message: m}) when is_binary(m), do: m
  defp message(%Postgrex.Error{} = e), do: Exception.message(e)
  defp message(m) when is_binary(m), do: m
  defp message(other), do: inspect(other)

  defp clip(v, max \\ 200)
  defp clip(v, max) when is_binary(v), do: v |> String.trim() |> String.slice(0, max) |> then(&if(&1 == "", do: nil, else: &1))
  defp clip(_, _), do: nil

  defp now_ms, do: System.system_time(:millisecond)
  defp ms_to_dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp dt_to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(nil), do: nil

  # these atoms exist before any row is read
  @doc false
  def columns, do: ~w(id key source node severity title first_text state opened_at last_seen_at cleared_at done_at done_by looking_by note seen_count evidence objective_id at kind by)a
end
