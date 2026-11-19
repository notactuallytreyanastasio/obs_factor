defmodule ObsFactor.Ticker do
  @moduledoc """
  Builds one snapshot per tick from the latest source results, stores it for
  `GET /api/snapshot`, records it into `ObsFactor.History` and broadcasts it
  (already JSON-encoded, once) to every `GET /api/stream` subscriber.

  If building raises, the error is logged with its stacktrace and stored in
  place of the snapshot: the API answers 500 with it rather than serving the
  previous tick as if it were current.
  """

  use GenServer
  require Logger

  alias ObsFactor.{History, Snapshot, Sources, Store}

  @topic "snapshots"

  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.send_after(self(), :tick, Keyword.get(opts, :first_after_ms, 1_500))
    {:ok, %{memory: Snapshot.empty_memory(), tick_ms: Keyword.fetch!(opts, :tick_ms)}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, %{state | memory: tick(state.memory)}}
  end

  @doc "Builds, stores, records and broadcasts one snapshot. Returns the new memory."
  def tick(memory) do
    now = DateTime.utc_now()
    sources = Sources.all(DateTime.to_unix(now, :millisecond))

    try do
      {snapshot, memory} = Snapshot.build(ObsFactor.topology(), sources, memory, now)
      json = Jason.encode!(snapshot)
      Store.put_snapshot({:ok, json})
      History.record(DateTime.to_unix(now, :millisecond), History.metrics(snapshot, sources))
      Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:snapshot, json})
      memory
    rescue
      e ->
        message = Exception.format(:error, e, __STACKTRACE__)
        Logger.error("snapshot build failed: " <> message)
        Store.put_snapshot({:error, Exception.message(e)})
        memory
    end
  end
end
