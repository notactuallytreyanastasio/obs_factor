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
    {:ok, %{memory: Snapshot.empty_memory(), wire: ObsFactor.Wire.new(), tick_ms: Keyword.fetch!(opts, :tick_ms)}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {memory, wire} = tick(state.memory, state.wire)
    {:noreply, %{state | memory: memory, wire: wire}}
  end

  @doc """
  Builds, stores, records and broadcasts one snapshot, and reads the BEAM
  wire off it (`ObsFactor.Wire`). Returns the new memory and wire state.
  """
  def tick(memory, wire \\ ObsFactor.Wire.new()) do
    now = DateTime.utc_now()
    sources = Sources.all(DateTime.to_unix(now, :millisecond))

    try do
      {snapshot, memory} = Snapshot.build(ObsFactor.topology(), sources, memory, now)
      json = Jason.encode!(snapshot)
      Store.put_snapshot({:ok, json})
      metrics = History.metrics(snapshot, sources)
      History.record(DateTime.to_unix(now, :millisecond), metrics)
      Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:snapshot, json})
      at = DateTime.to_unix(now, :millisecond)
      {items, beam, wire} = read_wire(wire, json, at)
      # burn flags that started since the last tick (ObsFactor.SLOs): on the wire like any item
      items = items ++ ObsFactor.SLOs.drain()
      ObsFactor.Tape.record(at, json, ObsFactor.Tape.summary(snapshot, metrics, beam, items))
      ObsFactor.Objectives.observe(snapshot.attention, Map.new(snapshot.nodes, &{&1.id, &1}))
      {memory, wire}
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
        {memory, wire}
    end
  end

  # The wire reads the snapshot as the browser does (JSON), with the
  # mailboxes the observer engine last reported. A wire that raises loses
  # its news for this tick, not the snapshot.
  defp read_wire(wire, json, at) do
    snap = Jason.decode!(json)
    boxes = ObsFactor.Wire.Mailboxes.read()
    {items, wire} = ObsFactor.Wire.observe(wire, snap, at, boxes)
    {items, ObsFactor.Wire.metrics(snap, boxes), wire}
  rescue
    e ->
      Logger.error("wire failed: " <> Exception.message(e),
        event: "wire.failed",
        reason: Exception.message(e),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      {[], %{}, wire}
  end
end
