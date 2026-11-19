defmodule ObsFactor.Docker do
  @moduledoc """
  Docker collector. Each tick: the container list, then for every container an
  inspect and (if running) a one-shot stats call, all concurrently with a
  per-call deadline. A container whose stats call is slow gets `stats_error`
  for this tick; it does not hold up the other eighteen.

  Rates (CPU cores, network bytes/s) are deltas between this collector's own
  successive samples of the same container id.
  """

  @behaviour ObsFactor.Collector

  alias ObsFactor.Docker.Parse
  alias ObsFactor.Rate

  @call_timeout 2_500
  @restart_window_ms 15 * 60 * 1000

  @impl true
  def name, do: :docker

  @impl true
  def init_state(opts) do
    %{url: Keyword.get(opts, :url), samples: %{}, restarts: %{}}
  end

  @impl true
  def collect(%{url: nil} = state), do: {:error, "DOCKER_URL is not set", state}

  def collect(%{url: url} = state) do
    base = String.trim_trailing(url, "/")

    case ObsFactor.Http.get(base <> "/containers/json?all=1", timeout: @call_timeout) do
      {:ok, 200, list, _} when is_list(list) ->
        entries = Enum.map(list, &Parse.list_entry/1)
        now_ms = System.system_time(:millisecond)

        details =
          entries
          |> Task.async_stream(&fetch_details(base, &1),
            max_concurrency: 40,
            timeout: @call_timeout + 500,
            on_timeout: :kill_task,
            ordered: true
          )
          |> Enum.zip(entries)
          |> Enum.map(fn
            {{:ok, details}, _entry} ->
              details

            {{:exit, :timeout}, entry} ->
              %{inspect: {:error, "timed out"}, stats: {:error, "timed out"}, entry: entry}
          end)

        {containers, samples, restarts} = assemble(details, state, now_ms)
        {:ok, %{containers: containers}, %{state | samples: samples, restarts: restarts}}

      {:ok, status, _body, _} ->
        {:error, "GET /containers/json answered #{status}", state}

      {:error, message} ->
        {:error, message, state}
    end
  end

  defp fetch_details(base, entry) do
    inspect =
      case ObsFactor.Http.get("#{base}/containers/#{entry.id}/json",
             timeout: @call_timeout,
             decode: false
           ) do
        {:ok, 200, raw, _} -> Parse.inspect_body(raw)
        {:ok, status, _, _} -> {:error, "inspect answered #{status}"}
        {:error, message} -> {:error, "inspect: #{message}"}
      end

    stats =
      if entry.state == "running" do
        case ObsFactor.Http.get("#{base}/containers/#{entry.id}/stats?stream=false&one-shot=true",
               timeout: @call_timeout
             ) do
          {:ok, 200, body, _} when is_map(body) -> parse_stats(body)
          {:ok, status, _, _} -> {:error, "stats answered #{status}"}
          {:error, message} -> {:error, "stats: #{message}"}
        end
      else
        :not_running
      end

    %{inspect: inspect, stats: stats, entry: entry}
  end

  # A stats body we cannot read is this container's problem, not the tick's.
  defp parse_stats(body) do
    {:ok, Parse.stats(body)}
  rescue
    e -> {:error, ObsFactor.Collector.short(Exception.message(e))}
  end

  @doc false
  # Pure: joins list entries, inspects and stats with the previous samples.
  def assemble(details, state, now_ms) do
    results =
      Enum.map(details, fn %{entry: entry, inspect: inspect, stats: stats} ->
        prev = Map.get(state.samples, entry.id)
        sample = with {:ok, s} <- stats, do: s, else: (_ -> nil)

        rates = if sample && prev, do: rates(prev, sample), else: %{}

        {restart_count, info} =
          case inspect do
            {:ok, i} -> {i.restart_count, i}
            {:error, _} -> {nil, nil}
          end

        history = restart_history(Map.get(state.restarts, entry.id, []), restart_count, now_ms)

        container =
          entry
          |> Map.merge(%{
            inspect: info,
            inspect_error: with({:error, m} <- inspect, do: m, else: (_ -> nil)),
            stats_error: with({:error, m} <- stats, do: m, else: (_ -> nil)),
            mem_bytes: sample && sample.mem_bytes,
            cpu_cores: rates[:cpu_cores],
            net_rx_bps: rates[:net_rx_bps],
            net_tx_bps: rates[:net_tx_bps],
            restarts_recent: restarts_in_window(history)
          })

        {container, {entry.id, sample}, {entry.id, history}}
      end)

    containers = Enum.map(results, &elem(&1, 0))

    samples =
      for {_, {id, s}, _} <- results, into: %{} do
        # Keep the old sample when this tick's stats failed, so the next good one has a base.
        {id, s || Map.get(state.samples, id)}
      end
      |> Map.reject(fn {_, s} -> s == nil end)

    restarts = Map.new(results, &elem(&1, 2))
    {containers, samples, restarts}
  end

  @doc """
  Rates between two samples of the same container. CPU is computed the way
  `docker stats` does: the container's share of the host's CPU time over the
  interval, times the online CPUs, which is in cores.
  """
  def rates(prev, cur) do
    dt_s = DateTime.diff(cur.read_at, prev.read_at, :microsecond) / 1_000_000
    d_sys = cur.system_ns - prev.system_ns
    d_cpu = cur.cpu_total_ns - prev.cpu_total_ns

    cpu =
      if d_sys > 0 and d_cpu >= 0, do: d_cpu / d_sys * cur.online_cpus, else: nil

    %{
      cpu_cores: cpu,
      net_rx_bps: Rate.per_second(prev.rx_bytes, cur.rx_bytes, dt_s),
      net_tx_bps: Rate.per_second(prev.tx_bytes, cur.tx_bytes, dt_s)
    }
  end

  defp restart_history(history, nil, _now), do: history

  defp restart_history(history, count, now_ms) do
    kept = Enum.filter(history, fn {t, _} -> now_ms - t <= @restart_window_ms end)
    kept ++ [{now_ms, count}]
  end

  # Restarts seen within the window: the sum of the rises between successive
  # readings. Not last - first: `docker restart` resets RestartCount to 0
  # (verified in the lab), and the crash loop after it counts up from there.
  @doc false
  def restarts_in_window(history) do
    history
    |> Enum.map(&elem(&1, 1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> max(b - a, 0) end)
    |> Enum.sum()
  end
end
