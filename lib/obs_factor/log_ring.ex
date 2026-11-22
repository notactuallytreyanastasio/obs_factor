defmodule ObsFactor.LogRing do
  @moduledoc """
  The observer's own log, the last 2000 events, kept in memory so the page
  can show it (`GET /api/beam`, the "Under the hood" panel).

  A `:logger` handler, added beside the default one (which still writes to
  stdout, where `docker logs` reads it). Its `log/2` runs in the process
  that logged, so it does one ETS insert and nothing that can block; this
  GenServer only owns the table and trims it. Events from before it starts
  (the first lines of boot) are not in it: stdout has them.
  """

  use GenServer

  @table __MODULE__
  @keep 2000
  @handler :obs_factor_ring

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :ordered_set, write_concurrency: true])
    _ = :logger.remove_handler(@handler)
    :ok = :logger.add_handler(@handler, __MODULE__, %{level: :all})
    :timer.send_interval(5_000, :trim)
    {:ok, nil}
  end

  @impl true
  def handle_info(:trim, s) do
    over = :ets.info(@table, :size) - @keep
    if over > 0, do: Enum.each(Enum.take(keys(), over), &:ets.delete(@table, &1))
    {:noreply, s}
  end

  @impl true
  def terminate(_, _), do: :logger.remove_handler(@handler)

  defp keys, do: Stream.unfold(:ets.first(@table), fn :"$end_of_table" -> nil; k -> {k, :ets.next(@table, k)} end)

  # ---- :logger handler callback ----------------------------------------------

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    if :ets.whereis(@table) != :undefined do
      id = System.unique_integer([:monotonic, :positive])

      :ets.insert(@table, {id, %{
        id: id,
        at: div(Map.get(meta, :time, :os.system_time(:microsecond)), 1000),
        level: level,
        text: text(msg) |> String.slice(0, 2_000),
        where: where(meta),
        pid: meta |> Map.get(:pid) |> pid_text(),
        attrs: attrs(meta)
      }})
    end

    :ok
  end

  # Logger metadata as searchable attributes (the explorer's facets):
  # request_id from Plug, source from the collectors, file and line, and
  # whatever else a caller passed. Process plumbing is left out.
  @drop [:time, :gl, :pid, :mfa, :report_cb, :error_logger, :logger_formatter, :erl_level, :callers, :ancestors]
  defp attrs(meta) do
    for {k, v} <- meta, k not in @drop, into: %{} do
      {k, attr(k, v)}
    end
  end

  defp attr(:domain, d) when is_list(d), do: Enum.join(d, ".")
  defp attr(_, v) when is_binary(v), do: String.slice(v, 0, 300)
  defp attr(_, v) when is_number(v) or is_boolean(v), do: v
  defp attr(_, v) when is_atom(v) do
    t = Atom.to_string(v)
    if String.starts_with?(t, "Elixir."), do: inspect(v), else: t
  end
  defp attr(_, v) when is_list(v), do: if(List.ascii_printable?(v), do: to_string(v), else: inspect(v, limit: 10))
  defp attr(_, v), do: inspect(v, limit: 10, printable_limit: 300)

  defp text({:string, s}), do: IO.chardata_to_string(s)
  defp text({:report, r}), do: inspect(r, limit: 20, printable_limit: 500)
  defp text({fmt, args}), do: fmt |> :io_lib.format(args) |> IO.chardata_to_string()

  defp where(%{mfa: {m, f, a}}), do: "#{inspect(m)}.#{f}/#{a}"
  defp where(_), do: nil

  defp pid_text(p) when is_pid(p), do: p |> :erlang.pid_to_list() |> to_string()
  defp pid_text(_), do: nil

  @levels ~w(debug info notice warning error critical alert emergency)a

  @doc "The newest `limit` events at `min_level` or worse, oldest first."
  def recent(limit \\ 200, min_level \\ :debug) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      floor = Enum.find_index(@levels, &(&1 == min_level)) || 0

      :ets.tab2list(@table)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&((Enum.find_index(@levels, fn l -> l == &1.level end) || 0) >= floor))
      |> Enum.take(-limit)
    end
  end

  def levels, do: @levels
  def keep, do: @keep

  @doc "Every event kept with an id above `after` (0: all of them), oldest first."
  def since(after_id) do
    if :ets.whereis(@table) == :undefined,
      do: [],
      else: :ets.select(@table, [{{:"$1", :"$2"}, [{:>, :"$1", after_id}], [:"$2"]}])
  end
end
