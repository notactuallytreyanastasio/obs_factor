defmodule ObsFactor.Alerts.Engine do
  @moduledoc """
  Listens for what `ObsFactor.Alerts` sends, groups it, and sends it.

  It hears two things on `ObsFactor.PubSub`, and the ticker never waits on
  it:

    * `{:objective, row}` on `"objectives"`: a row whose newest event is
      `seen` or `came back` (and recent: after a restart the 30 s flush of an
      old objective is not news) fires; one whose newest event is `cleared
      itself` or `crossed off` resolves, for the routes that were told it
      fired;
    * `{:tape_frame, tick}` on `"tape"`: the tick's wire items.

  Items are held for `flush_ms` (1.5 s) from the first one: an objective
  and the wire item about the same crash arrive a few milliseconds apart
  from the same tick, and a burst is one message per route, listing them.
  The same key (an objective's key, or app, kind and member for a wire
  item) goes to a route at most once per the route's `dedup_minutes`.

  Each route's message is sent from a task under `ObsFactor.TaskSupervisor`
  and retried once after `retry_ms` (5 s); the result is written on the
  route (`last_sent_at` or `last_error`) and the routes are broadcast on
  the `alerts` topic.

  What it has told whom is in memory: after a restart, a route is not sent
  the resolved message for an objective it was told about before.
  """
  use GenServer
  require Logger

  alias ObsFactor.{Alerts, Tape}

  # An objective's transition is broadcast the moment its event is written;
  # the same row is broadcast again by the 30 s last_seen flush, with the
  # same newest event. Only an event this fresh is the transition itself,
  # so a restarted engine (which remembers nothing) does not fire on a
  # flush. (120 s here re-sent an objective crossed off a moment before:
  # seen on the laptop, 2026-11-24.)
  @fire_window_ms 15_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Send what is held now (tests)."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, Keyword.get(opts, :objectives_topic, "objectives"))
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, Keyword.get(opts, :tape_topic, Tape.topic()))

    {:ok,
     %{
       db: Keyword.get(opts, :db, Tape.db()),
       # nil: a job per delivery when Oban runs (ObsFactor.Jobs.Webhook,
       # retried for a quarter of an hour), else posted here; tests pass one
       post: Keyword.get(opts, :post),
       base_url: Keyword.get(opts, :base_url),
       flush_ms: Keyword.get(opts, :flush_ms, 1_500),
       retry_ms: Keyword.get(opts, :retry_ms, 5_000),
       now: Keyword.get(opts, :now, fn -> System.system_time(:millisecond) end),
       pending: [],
       timer: nil,
       sent: %{},
       told: %{},
       fired: MapSet.new()
     }}
  end

  @impl true
  def handle_info({:objective, row}, state) do
    {items, state} = from_objective(row, state)
    {:noreply, state |> drop_unsent(row, items) |> hold(items)}
  end

  def handle_info({:tape_frame, tick}, state) do
    items = for w <- Map.get(tick, :wire, []), w[:sev] in ~w(alert warn), do: from_wire(w)
    {:noreply, hold(state, items)}
  end

  def handle_info(:flush, state), do: {:noreply, send_out(%{state | timer: nil})}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, :ok, send_out(%{state | timer: nil})}
  end

  # ---- items ----------------------------------------------------------------

  defp from_objective(%{source: "pin"}, state), do: {[], state}

  defp from_objective(row, state) do
    last = List.last(row[:events] || []) || %{}
    at = ms(last[:at]) || state.now.()
    label = get_in(row, [:evidence, "label"]) || get_in(row, [:evidence, :label])

    base = %{severity: row.severity, source: "objective", kind: "objective", app: row.node, label: label,
             key: "obj:" <> row.key, objective_id: row.id, title: row.title, at: at}

    cond do
      row.state == "open" and last[:kind] in ["seen", "came back"] and state.now.() - at <= @fire_window_ms and
          not MapSet.member?(state.fired, {row.id, row.seen_count}) ->
        detail = if row.seen_count > 1, do: "back again: seen #{row.seen_count} times", else: "new"
        {[Map.merge(base, %{state: "firing", detail: detail})], %{state | fired: MapSet.put(state.fired, {row.id, row.seen_count})}}

      row.state in ["cleared", "done"] and last[:kind] in ["cleared itself", "crossed off"] and Map.has_key?(state.told, row.id) ->
        detail =
          if last[:kind] == "crossed off",
            do: "crossed off#{if last[:by], do: " by #{last[:by]}"}#{if last[:note], do: ": #{last[:note]}"}",
            else: "cleared itself"

        {[Map.merge(base, %{state: "resolved", detail: detail})], state}

      true ->
        {[], state}
    end
  end

  defp from_wire(w) do
    %{state: "firing", severity: w.sev, source: "wire", kind: w.kind, app: w.app, label: w[:label], member: w[:member],
      key: "wire:#{w.app}|#{w.kind}|#{w[:member]}", title: w.head, detail: w[:text], at: w[:at]}
  end

  # cleared or crossed off before its firing went out: neither is sent
  defp drop_unsent(state, %{state: s, id: id}, _) when s in ["cleared", "done"],
    do: %{state | pending: Enum.reject(state.pending, &(&1[:objective_id] == id and &1.state == "firing"))}

  defp drop_unsent(state, _, _), do: state

  defp hold(state, []), do: state

  defp hold(state, items) do
    timer = state.timer || Process.send_after(self(), :flush, state.flush_ms)
    %{state | pending: state.pending ++ items, timer: timer}
  end

  # ---- sending ----------------------------------------------------------------

  defp send_out(%{pending: []} = state), do: state

  defp send_out(state) do
    items = state.pending
    state = %{state | pending: []}

    case Alerts.routes(state.db) do
      {:ok, routes} ->
        now = state.now.()
        specs = specs(state.db, routes)
        base = state.base_url || ObsFactorWeb.Endpoint.url()

        state =
          routes
          |> Enum.filter(& &1.enabled)
          |> Enum.reject(&Alerts.quiet?(&1, now))
          |> Enum.reduce(state, fn route, st ->
            chosen =
              items
              |> Enum.filter(&Alerts.wants?(route, &1, specs[route.filter_id]))
              |> Enum.uniq_by(&{&1.key, &1.state})
              |> Enum.filter(fn
                %{state: "firing", key: k} -> fresh?(st, route, k, now)
                %{state: "resolved", objective_id: oid} -> MapSet.member?(Map.get(st.told, oid, MapSet.new()), route.id)
              end)

            if chosen == [] do
              st
            else
              deliver(st, route, Alerts.message(route, chosen, base))
              remember(st, route, chosen, now)
            end
          end)

        # a resolved objective is forgotten: if it comes back, it fires anew
        resolved = for %{state: "resolved", objective_id: oid} <- items, do: oid
        %{state | told: Map.drop(state.told, resolved), sent: prune(state.sent, now)}

      {:error, e} ->
        Logger.warning("alerts: cannot read the routes, #{length(items)} item(s) not sent: #{Tape.message(e)}",
          event: "alerts.routes_failed", reason: Tape.message(e))

        state
    end
  end

  defp fresh?(st, route, key, now) do
    case st.sent[{route.id, key}] do
      nil -> true
      at -> now - at >= route.dedup_minutes * 60_000
    end
  end

  defp remember(st, route, chosen, now) do
    Enum.reduce(chosen, st, fn
      %{state: "firing"} = i, s ->
        told = if i[:objective_id], do: Map.update(s.told, i.objective_id, MapSet.new([route.id]), &MapSet.put(&1, route.id)), else: s.told
        %{s | sent: Map.put(s.sent, {route.id, i.key}, now), told: told}

      _, s ->
        s
    end)
  end

  # dedup marks older than a day are no use to any route (1440 minutes at most)
  defp prune(sent, now), do: Map.reject(sent, fn {_, at} -> now - at > 86_400_000 end)

  defp specs(db, routes) do
    if Enum.any?(routes, & &1.filter_id) do
      case ObsFactor.WireFilters.list(db) do
        {:ok, sets} -> Map.new(sets, &{&1.id, &1.spec})
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp deliver(%{post: nil} = st, route, body) do
    if ObsFactor.Jobs.enabled?() do
      case ObsFactor.Jobs.Webhook.enqueue_for(:alert, route.id).(route.url, body) do
        :ok -> Logger.info("alert to #{route.name} enqueued: #{length(body.items)} item(s)", event: "alerts.enqueued", route: route.id)
        {:error, e} -> Alerts.record(route.id, {:error, e}, st.db)
      end
    else
      deliver(%{st | post: &ObsFactor.WebhookGuard.post/2}, route, body)
    end
  end

  defp deliver(st, route, body) do
    %{post: post, retry_ms: retry, db: db} = st

    Task.Supervisor.start_child(ObsFactor.TaskSupervisor, fn ->
      result =
        case post.(route.url, body) do
          :ok ->
            :ok

          {:error, first} ->
            Process.sleep(retry)

            case post.(route.url, body) do
              :ok -> :ok
              {:error, e} -> {:error, if(e == first, do: "#{e} (twice)", else: "#{e} (first try: #{first})")}
            end
        end

      case result do
        :ok -> Logger.info("alert sent to #{route.name}: #{length(body.items)} item(s)", event: "alerts.sent", route: route.id)
        {:error, e} -> Logger.warning("alert to #{route.name} failed: #{e}", event: "alerts.failed", route: route.id, reason: e)
      end

      Alerts.record(route.id, result, db)
      Alerts.broadcast(db)
    end)
  end

  defp ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp ms(_), do: nil
end
