defmodule ObsFactorWeb.TapeChannel do
  @moduledoc """
  `tape`: the replay (`ObsFactor.Tape`) and the Fires panel
  (`ObsFactor.Insights`).

  The join reply is `%{range: %{from, to, frames}, tick_ms}`, or
  `%{error: reason}` when there is no tape (no objectives store) or
  Postgres does not answer; the join succeeds either way. Then a `tick`
  push per frame written: `%{at, alerts, warns, down, blocked, rps,
  err_rps, fires, top, metrics}` (fires: how many attention
  lines; top: the first six of them; metrics: the board's numbers per node), so the timeline's
  live edge grows.

  Reads, as pushes answered with `{:ok, reply}` or `{:error, %{error}}`:

    * `index` `%{from, to, buckets}`: the timeline strip (`Tape.index/3`)
    * `frame` `%{at}`: `%{at, next, snapshot}`, the snapshot as it was then and
      when the next frame is (nil: this is the newest)
    * `series` `%{from, to, points, prefix}` (prefix optional, e.g. `"beam:"`): `%{series: [[at, %{node => %{key => n}}]]}`,
      the board's numbers per node, at most `points` frames (`Tape.series/4`)
    * `lanes` `%{from, to}`: `%{lanes: [[node, severity, from, to, frames, text]]}`,
      each building's runs of alerts and warnings (`Tape.lanes/3`)
    * `windows` `%{}`: `%{windows: [window]}`
    * `wire` `%{from, to, limit, kinds}`: `%{wire: [item]}`, the BEAM wire
      (`ObsFactor.Wire`), newest first, at most `limit` (500; up to 5000),
      only `kinds` when given
    * `marks` `%{from, to}`: `%{marks: [[at, kind, id, node, severity, title, by]]}`
    * `insights` `%{from, to}`: `ObsFactor.Insights.compute/2`

  Writes, replied with `{:ok, %{window}}` / `{:ok, %{pruned: ids}}` or
  `{:error, %{error}}`, and followed by a `windows` push `%{windows: list}`
  to everyone on the topic:

    * `save_window` `%{from, to, title, note, by}`, or with `id` to change
      one (trim its edges, rename it)
    * `prune_windows` `%{ids}`: marked pruned; for an hour they are still
      listed (with `pruned_at`) and their frames still kept
    * `restore_windows` `%{ids}`: undo a prune from the last hour
    * `save_filter` `%{name, spec, by}` (with `id`: change one) and
      `delete_filter` `%{id}`: the wire's saved filter sets
      (`ObsFactor.WireFilters`), followed by a `filters` push
      `%{filters: list}` to everyone; the join reply carries `filters` too

  Times are unix milliseconds. A window may be at most 31 days.
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.{Insights, Tape}

  @max_window_ms 31 * 86_400_000

  @impl true
  def join("tape", _params, socket) do
    reply =
      if Tape.enabled?() do
        case Tape.range() do
          {:ok, r} ->
            %{range: r, tick_ms: Application.get_env(:obs_factor, :tick_ms), windows: ok_or(Tape.windows(), []),
              filters: ok_or(ObsFactor.WireFilters.list(), [])}
          {:error, e} -> %{error: "tape: " <> Tape.message(e)}
        end
      else
        %{error: "no tape: OBJECTIVES_PG_URL is not set"}
      end

    {:ok, reply, socket}
  end

  @impl true
  def handle_info({:tape_frame, tick}, socket) do
    push(socket, "tick", tick)
    {:noreply, socket}
  end

  def handle_info({:wire_filters, list}, socket) do
    push(socket, "filters", %{filters: list})
    {:noreply, socket}
  end

  def handle_info({:tape_windows, list}, socket) do
    push(socket, "windows", %{windows: list})
    {:noreply, socket}
  end

  @impl true
  def handle_in("save_window", params, socket) when is_map(params), do: {:reply, write(fn -> Tape.save_window(params) end, :window), socket}

  def handle_in("prune_windows", %{"ids" => ids}, socket) when is_list(ids),
    do: {:reply, write(fn -> Tape.prune_windows(ids) end, :pruned), socket}

  def handle_in("save_filter", params, socket) when is_map(params),
    do: {:reply, filters(fn -> ObsFactor.WireFilters.save(params) end, :filter), socket}

  def handle_in("delete_filter", %{"id" => id}, socket),
    do: {:reply, filters(fn -> ObsFactor.WireFilters.delete(id) end, :deleted), socket}

  def handle_in("restore_windows", %{"ids" => ids}, socket) when is_list(ids),
    do: {:reply, write(fn -> Tape.restore_windows(ids) end, :restored), socket}

  def handle_in(event, params, socket) do
    {:reply, if(Tape.enabled?(), do: read(event, params), else: {:error, %{error: "no tape: OBJECTIVES_PG_URL is not set"}}), socket}
  end

  defp read("index", %{"from" => f, "to" => t, "buckets" => b}) when is_integer(b) and b in 1..2000,
    do: window(f, t, fn f, t -> Tape.index(f, t, b) end)

  defp read("frame", %{"at" => at}) when is_integer(at) do
    case Tape.frame(at) do
      {:ok, at, json, next} -> {:ok, %{at: at, next: next, snapshot: Jason.Fragment.new(json)}}
      :none -> {:error, %{error: "the tape is empty"}}
      {:error, e} -> {:error, %{error: Tape.message(e)}}
    end
  end

  defp read("series", %{"from" => f, "to" => t, "points" => p} = a) when is_integer(p) and p in 1..2000 do
    prefix = if is_binary(a["prefix"]) and byte_size(a["prefix"]) in 1..20, do: a["prefix"]
    window(f, t, fn f, t -> wrap(Tape.series(f, t, p, Tape.db(), prefix), :series) end)
  end

  defp read("wire", %{"from" => f, "to" => t} = a) do
    limit = if is_integer(a["limit"]) and a["limit"] in 1..5000, do: a["limit"], else: 500
    kinds = if is_list(a["kinds"]) and Enum.all?(a["kinds"], &is_binary/1) and length(a["kinds"]) <= 40, do: a["kinds"]
    window(f, t, fn f, t -> wrap(Tape.wire(f, t, limit, Tape.db(), kinds), :wire) end)
  end
  defp read("lanes", %{"from" => f, "to" => t}), do: window(f, t, fn f, t -> wrap(Tape.lanes(f, t), :lanes) end)
  defp read("windows", _), do: wrap(Tape.windows(), :windows) |> err()

  defp read("marks", %{"from" => f, "to" => t}), do: window(f, t, fn f, t -> wrap(Tape.marks(f, t), :marks) end)
  defp read("insights", %{"from" => f, "to" => t}), do: window(f, t, &Insights.compute/2)

  defp read(event, params),
    do: {:error, %{error: "tape: cannot #{inspect(event)} with #{inspect(params)}"}}

  defp window(f, t, fun) when is_integer(f) and is_integer(t) and t > f and t - f <= @max_window_ms do
    case fun.(f, t) do
      {:ok, r} -> {:ok, r}
      {:error, e} -> {:error, %{error: Tape.message(e)}}
    end
  end

  defp window(f, t, _),
    do: {:error, %{error: "a window is two integer unix ms times, from before to, at most 31 days: got #{inspect(f)}..#{inspect(t)}"}}

  # a write, then everyone on the topic gets the whole list of windows
  defp write(fun, key) do
    if Tape.enabled?() do
      case fun.() do
        {:ok, v} ->
          with {:ok, list} <- Tape.windows(), do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, Tape.topic(), {:tape_windows, list})
          {:ok, %{key => v}}

        {:error, e} ->
          {:error, %{error: Tape.message(e)}}
      end
    else
      {:error, %{error: "no tape: OBJECTIVES_PG_URL is not set"}}
    end
  end

  # a write to the filter sets, then everyone gets the whole list
  defp filters(fun, key) do
    if Tape.enabled?() do
      case fun.() do
        {:ok, v} ->
          with {:ok, list} <- ObsFactor.WireFilters.list(),
               do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, Tape.topic(), {:wire_filters, list})

          {:ok, %{key => v}}

        {:error, e} ->
          {:error, %{error: Tape.message(e)}}
      end
    else
      {:error, %{error: "no tape: OBJECTIVES_PG_URL is not set"}}
    end
  end

  defp ok_or({:ok, v}, _), do: v
  defp ok_or(_, d), do: d

  defp err({:error, e}), do: {:error, %{error: Tape.message(e)}}
  defp err(ok), do: ok

  defp wrap({:ok, v}, key), do: {:ok, %{key => v}}
  defp wrap(e, _), do: e
end
