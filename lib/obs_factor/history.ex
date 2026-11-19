defmodule ObsFactor.History do
  @moduledoc """
  In-memory history: every tick for the last hour (5 s resolution, 720
  points) and one-minute averages for the last 24 hours (1440 points).
  Nothing is written to disk; a restart starts empty.

  A tick is recorded as `{unix_ms, %{node_id => %{key => value | nil}}}`. A
  minute's average ignores nils and is nil when every value was nil.
  """

  use GenServer

  @fine_keep 720
  @coarse_keep 1440
  @minute 60_000

  # key => {label, unit}, in the order series are returned.
  @series [
    rps: {"Requests", "req/s"},
    err_rps: {"5xx", "req/s"},
    avg_ms: {"Latency", "ms"},
    cpu_cores: {"CPU", "cores"},
    mem_bytes: {"Memory", "B"},
    net_rx_bps: {"Network in", "B/s"},
    net_tx_bps: {"Network out", "B/s"},
    commits_per_s: {"Commits", "commits/s"},
    connections: {"Connections", "connections"},
    cpu_used_cores: {"CPU used", "cores"},
    mem_used_bytes: {"Memory used", "B"},
    disk_used_pct: {"Disk used", "%"},
    bytes: {"Size", "B"}
  ]

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  def record(server \\ __MODULE__, at_ms, metrics),
    do: GenServer.cast(server, {:record, at_ms, metrics})

  @doc "`{:ok, series}` or `:unknown_node`. `res` is `\"5s\"` or `\"1m\"`."
  def query(server \\ __MODULE__, node, res) when res in ["5s", "1m"],
    do: GenServer.call(server, {:query, node, res})

  @doc "The values recorded for each node of a snapshot."
  def metrics(snapshot, sources) do
    pg = with %{ok: true, data: d} <- sources[:postgres], do: d, else: (_ -> nil)

    Map.new(snapshot.nodes, fn n ->
      m =
        %{}
        |> merge_container(n.container)
        |> merge_hosts(n.hosts)
        |> merge_kind(n, pg)

      {n.id, m}
    end)
  end

  defp merge_container(m, nil), do: m

  defp merge_container(m, c),
    do: Map.merge(m, Map.take(c, [:cpu_cores, :mem_bytes, :net_rx_bps, :net_tx_bps]))

  defp merge_hosts(m, []), do: m

  defp merge_hosts(m, hosts) do
    total = fn key ->
      values = Enum.map(hosts, &Map.get(&1, key))
      if Enum.any?(values, &is_nil/1), do: nil, else: Enum.sum(values) / 1
    end

    latencies = for %{avg_ms: v} <- hosts, is_number(v), do: v
    avg = if latencies == [], do: nil, else: Enum.sum(latencies) / length(latencies)
    Map.merge(m, %{rps: total.(:rps), err_rps: total.(:err_rps), avg_ms: avg})
  end

  defp merge_kind(m, %{kind: "db"} = n, pg) do
    Map.merge(m, %{commits_per_s: n.headline.value, connections: pg && pg.connections})
  end

  defp merge_kind(m, %{id: "host-cpu"} = n, _), do: Map.put(m, :cpu_used_cores, n.headline.value)
  defp merge_kind(m, %{id: "host-mem"} = n, _), do: Map.put(m, :mem_used_bytes, n.headline.value)
  defp merge_kind(m, %{id: "host-disk"} = n, _), do: Map.put(m, :disk_used_pct, n.headline.value)
  defp merge_kind(m, %{id: "internet"} = n, _), do: Map.put(m, :rps, n.headline.value)

  defp merge_kind(m, %{kind: "static", holds: [%{bytes: b}]}, _), do: Map.put(m, :bytes, b)
  defp merge_kind(m, _, _), do: m

  ## Server

  @impl true
  def init(:ok) do
    {:ok, %{fine: :queue.new(), fine_len: 0, coarse: :queue.new(), coarse_len: 0, bucket: nil}}
  end

  @impl true
  def handle_cast({:record, at_ms, metrics}, state) do
    minute = div(at_ms, @minute) * @minute

    state =
      case state.bucket do
        nil ->
          %{state | bucket: {minute, [metrics]}}

        {^minute, ticks} ->
          %{state | bucket: {minute, [metrics | ticks]}}

        {old, ticks} ->
          state |> push(:coarse, {old, average(ticks)}) |> Map.put(:bucket, {minute, [metrics]})
      end

    {:noreply, push(state, :fine, {at_ms, metrics})}
  end

  @impl true
  def handle_call({:query, node, res}, _from, state) do
    points =
      case res do
        "5s" -> :queue.to_list(state.fine)
        "1m" -> :queue.to_list(state.coarse)
      end

    known? =
      Enum.any?(:queue.to_list(state.fine), fn {_, m} -> Map.has_key?(m, node) end) or
        Enum.any?(:queue.to_list(state.coarse), fn {_, m} -> Map.has_key?(m, node) end)

    if known? do
      keys =
        points |> Enum.flat_map(fn {_, m} -> Map.keys(Map.get(m, node, %{})) end) |> MapSet.new()

      series =
        for {key, {label, unit}} <- @series, MapSet.member?(keys, key) do
          %{
            key: Atom.to_string(key),
            label: label,
            unit: unit,
            points:
              for {t, m} <- points, Map.has_key?(m, node) do
                [t, m |> Map.fetch!(node) |> Map.get(key)]
              end
          }
        end

      {:reply, {:ok, series}, state}
    else
      {:reply, :unknown_node, state}
    end
  end

  defp push(state, :fine, item) do
    {q, len} = trim(:queue.in(item, state.fine), state.fine_len + 1, @fine_keep)
    %{state | fine: q, fine_len: len}
  end

  defp push(state, :coarse, item) do
    {q, len} = trim(:queue.in(item, state.coarse), state.coarse_len + 1, @coarse_keep)
    %{state | coarse: q, coarse_len: len}
  end

  defp trim(q, len, keep) when len > keep, do: trim(:queue.drop(q), len - 1, keep)
  defp trim(q, len, _keep), do: {q, len}

  @doc false
  def average(ticks) do
    ticks
    |> Enum.flat_map(fn m ->
      Enum.flat_map(m, fn {node, kv} -> Enum.map(kv, fn {k, v} -> {{node, k}, v} end) end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(%{}, fn {{node, key}, values}, acc ->
      nums = Enum.filter(values, &is_number/1)
      avg = if nums == [], do: nil, else: Enum.sum(nums) / length(nums)
      Map.update(acc, node, %{key => avg}, &Map.put(&1, key, avg))
    end)
  end
end
