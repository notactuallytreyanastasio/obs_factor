defmodule ObsFactor.Caddy do
  @moduledoc """
  Caddy collector: fetches the Prometheus page at `CADDY_METRICS_URL` and turns
  the per-host counters into rates between successive scrapes.

  Series used (Caddy 2.10.2 with `metrics { per_host }`, see the fixture):

    * `caddy_http_requests_total{host}` - requests
    * `caddy_http_request_duration_seconds_count{code,host}` - requests by
      status class (2xx, 3xx, 4xx, 5xx, other)
    * `caddy_http_request_duration_seconds_sum/_count{host}` - average latency
    * `caddy_http_request_size_bytes_sum{host}` - request body bytes
    * `caddy_http_response_size_bytes_sum{host}` - response body bytes
    * `caddy_http_requests_in_flight{host}` - a gauge, read as it is
    * `process_start_time_seconds` - detects a Caddy restart

  A restart resets every counter. When the start time changes, or any counter
  goes backwards, every rate in that scrape is `nil`: no negative, no spike.
  A host that first appears between two scrapes of the same Caddy process
  started from zero (Prometheus creates the series on its first request).
  `in_flight` is not a rate: it is known on the first scrape and across a
  restart.

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

  @classes ["2xx", "3xx", "4xx", "5xx", "other"]

  # Everything that only ever grows within one Caddy process.
  @counters [:requests, :dur_count, :dur_sum, :in_bytes, :out_bytes] ++
              Enum.map(@classes, &{:code, &1})

  @doc "The status classes of `codes`, in order."
  def classes, do: @classes

  @doc """
  The status class of a `code` label: `"2xx"`..`"5xx"`, or `"other"` for every
  code outside 200-599 (101 upgrades, Caddy's `0`). Raises on a label that is
  not a number.
  """
  def class(code) when is_binary(code) do
    case Integer.parse(code) do
      {n, ""} when n in 200..599 -> "#{div(n, 100)}xx"
      {_, ""} -> "other"
      _ -> raise ArgumentError, "caddy metrics: code label is not a number: #{inspect(code)}"
    end
  end

  @doc "Cumulative per-host counters (and the in-flight gauge) from one metrics page."
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

        {"caddy_http_request_duration_seconds_count", %{"host" => h, "code" => code}, v}, acc ->
          acc |> bump(h, :dur_count, v) |> bump(h, {:code, class(code)}, v)

        {"caddy_http_request_duration_seconds_count", %{"host" => _} = labels, _}, _acc ->
          raise ArgumentError,
                "caddy metrics: caddy_http_request_duration_seconds_count without a code label: #{inspect(labels)}"

        {"caddy_http_request_duration_seconds_sum", %{"host" => h}, v}, acc ->
          bump(acc, h, :dur_sum, v)

        {"caddy_http_request_size_bytes_sum", %{"host" => h}, v}, acc ->
          bump(acc, h, :in_bytes, v)

        {"caddy_http_response_size_bytes_sum", %{"host" => h}, v}, acc ->
          bump(acc, h, :out_bytes, v)

        {"caddy_http_requests_in_flight", %{"host" => h}, v}, acc ->
          bump(acc, h, :in_flight, whole!(v, h))

        _, acc ->
          acc
      end)

    %{at_ms: at_ms, start: start, hosts: hosts}
  end

  defp whole!(v, host) do
    if is_float(v) and v >= 0 and Float.floor(v) == v do
      trunc(v)
    else
      raise ArgumentError,
            "caddy metrics: caddy_http_requests_in_flight for #{inspect(host)} is not a count: #{inspect(v)}"
    end
  end

  defp bump(acc, host, key, v) do
    Map.update(acc, host, Map.update!(zero(), key, &(&1 + v)), fn counters ->
      Map.update!(counters, key, &(&1 + v))
    end)
  end

  defp zero, do: @counters |> Map.new(&{&1, 0.0}) |> Map.put(:in_flight, 0)

  @doc """
  Rates between two readings. `prev` nil (first scrape) gives nil rates.
  Returns `%{hosts: %{host => host_rates}, total_rps, reset}` where
  `host_rates` is `%{rps, err_rps, avg_ms, codes, in_bps, out_bps, in_flight}`:
  `codes` maps each of `classes/0` to req/s, `err_rps` is its `"5xx"`, and
  `in_flight` is the gauge of the current reading (an integer, never nil).
  """
  def rates(prev, cur) do
    dt_s = if prev, do: (cur.at_ms - prev.at_ms) / 1000, else: nil

    reset =
      prev != nil and
        (prev.start != cur.start or
           Enum.any?(cur.hosts, fn {h, c} ->
             p = Map.get(prev.hosts, h, zero())
             Enum.any?(@counters, &(Map.fetch!(c, &1) < Map.fetch!(p, &1)))
           end) or
           Enum.any?(Map.keys(prev.hosts), &(not Map.has_key?(cur.hosts, &1))))

    known = prev != nil and not reset and dt_s > 0

    hosts =
      Map.new(cur.hosts, fn {h, c} ->
        if known do
          p = Map.get(prev.hosts, h, zero())
          rate = fn key -> (Map.fetch!(c, key) - Map.fetch!(p, key)) / dt_s end
          d_count = c.dur_count - p.dur_count
          codes = Map.new(@classes, &{&1, rate.({:code, &1})})

          {h,
           %{
             rps: rate.(:requests),
             err_rps: Map.fetch!(codes, "5xx"),
             avg_ms: if(d_count > 0, do: (c.dur_sum - p.dur_sum) / d_count * 1000, else: nil),
             codes: codes,
             in_bps: rate.(:in_bytes),
             out_bps: rate.(:out_bytes),
             in_flight: c.in_flight
           }}
        else
          {h,
           %{
             rps: nil,
             err_rps: nil,
             avg_ms: nil,
             codes: nil,
             in_bps: nil,
             out_bps: nil,
             in_flight: c.in_flight
           }}
        end
      end)

    total = if known, do: hosts |> Map.values() |> Enum.map(& &1.rps) |> Enum.sum(), else: nil
    %{hosts: hosts, total_rps: total, reset: reset}
  end
end
