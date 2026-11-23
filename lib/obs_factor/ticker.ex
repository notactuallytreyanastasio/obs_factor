defmodule ObsFactor.Ticker do
  @moduledoc """
  Builds one snapshot per tick from the latest source results, stores it for
  `GET /api/snapshot`, records it into `ObsFactor.History` and onto the tape (`ObsFactor.Tape`) and broadcasts it
  (already JSON-encoded, once) on `ObsFactor.PubSub` topic `"snapshots"` as
  `{:snapshot, json}`: the "snapshots" channel and `GET /api/stream` forward
  that binary as it is. A failed build is broadcast as
  `{:snapshot_error, message}`.

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
      metrics = History.metrics(snapshot, sources)
      History.record(DateTime.to_unix(now, :millisecond), metrics)
      Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:snapshot, json})
      ObsFactor.Tape.record(DateTime.to_unix(now, :millisecond), json, ObsFactor.Tape.summary(snapshot, metrics))
      ObsFactor.Objectives.observe(snapshot.attention, Map.new(snapshot.nodes, &{&1.id, &1}))
      memory
    rescue
      e ->
        Logger.error("snapshot build failed: " <> Exception.message(e),
          event: "snapshot.failed",
          kind: inspect(e.__struct__),
          reason: Exception.message(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        Store.put_snapshot({:error, Exception.message(e)})
        Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:snapshot_error, Exception.message(e)})
        memory
    end
  end
end
