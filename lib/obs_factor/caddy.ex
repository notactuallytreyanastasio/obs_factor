defmodule ObsFactor.Caddy do
  @moduledoc """
  Caddy collector: fetches the Prometheus page at `CADDY_METRICS_URL` and turns
  the per-host counters into rates between successive scrapes.

  Series used (Caddy 2.10.2 with `metrics { per_host }`, see the fixture):

    * `caddy_http_requests_total{host}` - requests
    * `caddy_http_request_duration_seconds_count{code,host}` - for 5xx by code
    * `caddy_http_request_duration_seconds_sum/_count{host}` - average latency
    * `process_start_time_seconds` - detects a Caddy restart

  A restart resets every counter. When the start time changes, or any counter
  goes backwards, every rate in that scrape is `nil`: no negative, no spike.
  A host that first appears between two scrapes of the same Caddy process
  started from zero (Prometheus creates the series on its first request).

  Series with `handler="metrics"` are dropped: they count our own scrapes
  (seen live on the lab's 2.10.2 as `host="127.0.0.1:19180"`, 0.2 req/s,
  exactly one per tick), not traffic.
  """

  @behaviour ObsFactor.Collector

  @impl true
  def name, do: :caddy

  @impl true
  def init_state(opts), do: %{url: Keyword.get(opts, :url), prev: nil}

  @impl true
  def collect(%{url: nil} = state), do: {:error, "CADDY_METRICS_URL is not set", state}

  def collect(%{url: url} = state) do
    case ObsFactor.Http.get(url, timeout: 2_000, decode: false) do
      {:ok, 200, body, _} ->
        reading = reading(body, System.system_time(:millisecond))
        {:ok, rates(state.prev, reading), %{state | prev: reading}}

      {:ok, status, _, _} ->
        {:error, "metrics answered #{status}", state}

      {:error, message} ->
        {:error, message, state}
    end
  end

  @doc "Cumulative per-host counters from one metrics page."
  def reading(text, at_ms) do
    samples = ObsFactor.Prometheus.parse(text)

    start =
      Enum.find_value(samples, fn
        {"process_start_time_seconds", _, v} -> v
        _ -> nil
      end)

    hosts =
      samples
      # The metrics endpoint's own series are our scrapes, not traffic.
      |> Enum.reject(fn {_, labels, _} -> labels["handler"] == "metrics" end)
      |> Enum.reduce(%{}, fn
        {"caddy_http_requests_total", %{"host" => h}, v}, acc ->
          bump(acc, h, :requests, v)

        {"caddy_http_request_duration_seconds_count", %{"host" => h} = l, v}, acc ->
          acc = bump(acc, h, :dur_count, v)
          if String.starts_with?(l["code"] || "", "5"), do: bump(acc, h, :errors, v), else: acc

        {"caddy_http_request_duration_seconds_sum", %{"host" => h}, v}, acc ->
          bump(acc, h, :dur_sum, v)

        _, acc ->
          acc
      end)

    %{at_ms: at_ms, start: start, hosts: hosts}
  end

  defp bump(acc, host, key, v) do
    Map.update(acc, host, Map.put(zero(), key, v), &Map.update!(&1, key, fn x -> x + v end))
  end

  defp zero, do: %{requests: 0.0, dur_count: 0.0, dur_sum: 0.0, errors: 0.0}

  @doc """
  Rates between two readings. `prev` nil (first scrape) gives nil rates.
  Returns `%{hosts: %{host => %{rps, err_rps, avg_ms}}, total_rps, reset}`.
  """
  def rates(prev, cur) do
    dt_s = if prev, do: (cur.at_ms - prev.at_ms) / 1000, else: nil

    reset =
      prev != nil and
        (prev.start != cur.start or
           Enum.any?(cur.hosts, fn {h, c} ->
             p = Map.get(prev.hosts, h, zero())

             Enum.any?(
               [:requests, :dur_count, :dur_sum, :errors],
               &(Map.fetch!(c, &1) < Map.fetch!(p, &1))
             )
           end) or
           Enum.any?(Map.keys(prev.hosts), &(not Map.has_key?(cur.hosts, &1))))

    known = prev != nil and not reset and dt_s > 0

    hosts =
      Map.new(cur.hosts, fn {h, c} ->
        if known do
          p = Map.get(prev.hosts, h, zero())
          d_count = c.dur_count - p.dur_count

          {h,
           %{
             rps: (c.requests - p.requests) / dt_s,
             err_rps: (c.errors - p.errors) / dt_s,
             avg_ms: if(d_count > 0, do: (c.dur_sum - p.dur_sum) / d_count * 1000, else: nil)
           }}
        else
          {h, %{rps: nil, err_rps: nil, avg_ms: nil}}
        end
      end)

    total = if known, do: hosts |> Map.values() |> Enum.map(& &1.rps) |> Enum.sum(), else: nil
    %{hosts: hosts, total_rps: total, reset: reset}
  end
end
