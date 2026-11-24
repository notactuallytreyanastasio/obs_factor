defmodule ObsFactor.Wire.Mailboxes do
  @moduledoc """
  The biggest mailboxes on every BEAM the observer can see into: every 15 s,
  for each node with a report (and each member of a cluster) and for the
  observer's own VM, the observer engine's `procs?sort=message_queue_len`,
  top 3. `ObsFactor.Wire` reads them: a process holding 100 or more
  messages is news, and the biggest mailbox goes on the tape.

  A node whose engine is not there (an app on an older factory_report
  answers 404) is left alone for 10 minutes before it is asked again, and
  says so once in the log.

  Each read also asks for the three hottest processes (reductions over
  500 ms, measured on the node) and the three biggest by memory.

  `read/0`: `%{{node_id, address | nil} => %{at, top: [proc], hot: [proc], big: [proc]}}`.
  """
  use GenServer
  require Logger

  alias ObsFactor.ObserverProxy

  @every_ms 15_000
  @backoff_ms 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def read do
    case GenServer.whereis(__MODULE__) do
      nil -> %{}
      _ -> GenServer.call(__MODULE__, :read, 1_000)
    end
  catch
    :exit, _ -> %{}
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :poll, Keyword.get(opts, :first_ms, 5_000))
    {:ok, %{boxes: %{}, off: %{}}}
  end

  @impl true
  def handle_call(:read, _from, state), do: {:reply, state.boxes, state}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @every_ms)
    now = System.monotonic_time(:millisecond)
    targets = for t <- targets(), due?(state.off, elem(t, 0), now), do: t

    results =
      targets
      |> Task.async_stream(&read_one/1, timeout: 8_000, on_timeout: :kill_task, max_concurrency: 8)
      |> Enum.zip(targets)

    state =
      Enum.reduce(results, state, fn
        {{:ok, {:ok, read}}, key}, st ->
          %{st | boxes: Map.put(st.boxes, key, Map.put(read, :at, System.system_time(:millisecond)))}

        {{:ok, {:error, 404, why}}, {id, _} = key}, st ->
          unless Map.has_key?(st.off, id),
            do: Logger.info("mailboxes: #{id} has no observer engine (#{why}); asking again in 10 min", event: "wire.mailboxes_off", node: id)

          %{st | off: Map.put(st.off, id, now + @backoff_ms), boxes: Map.delete(st.boxes, key)}

        {_, key}, st ->
          %{st | boxes: Map.delete(st.boxes, key)}
      end)

    {:noreply, state}
  end

  # monotonic time is negative on most VMs: "no backoff" is a missing key,
  # never 0 (`0 <= now` was false, and no node was ever asked)
  @doc false
  def due?(off, id, now) do
    case Map.fetch(off, id) do
      :error -> true
      {:ok, until} -> until <= now
    end
  end

  defp targets do
    reports =
      for n <- ObsFactor.topology().nodes, n.report do
        case ObserverProxy.members(n.id) do
          {:ok, [_ | _] = addrs} -> Enum.map(addrs, &{n.id, &1})
          _ -> [{n.id, nil}]
        end
      end

    [{ObserverProxy.self_id(), nil} | List.flatten(reports)]
  rescue
    _ -> []
  end

  # the three biggest mailboxes, the three hottest processes (reductions
  # over 500 ms, measured by the engine on the node), the three biggest
  # by memory; the mailboxes decide whether the node has an engine at all
  defp read_one({id, member}) do
    with {:ok, top} <- procs(id, member, %{"sort" => "message_queue_len", "limit" => "3"}) do
      hot = case procs(id, member, %{"sort" => "reductions", "limit" => "3", "interval_ms" => "500"}) do {:ok, p} -> p; _ -> [] end
      big = case procs(id, member, %{"sort" => "memory", "limit" => "3"}) do {:ok, p} -> p; _ -> [] end
      {:ok, %{top: top, hot: hot, big: big}}
    end
  end

  defp procs(id, member, params) do
    case ObserverProxy.call("GET", id, ["procs"], params, member: member) do
      {200, %{"procs" => procs}} -> {:ok, procs}
      {status, body} -> {:error, status, (is_map(body) && body["error"]) || "status #{status}"}
      other -> {:error, 0, inspect(other)}
    end
  end
end
