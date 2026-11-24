defmodule ObsFactor.Writeup.Scheduler do
  @moduledoc """
  Runs `ObsFactor.Writeup.Schedules` when they are due: it looks once a
  minute, runs each due schedule in a task (a week's writeup can take
  seconds), and broadcasts the schedules and the writeups on the `tape`
  topic when a run ends, so the Write up panel shows the result.
  """
  use GenServer
  require Logger

  alias ObsFactor.Writeup.Schedules

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run one schedule now, for the period that ends now. `{:ok, saved}` or `{:error, reason}`."
  def run_now(id) do
    with {:ok, list} <- Schedules.list(),
         %{} = s <- Enum.find(list, &(&1.id == id)) || {:error, "no schedule #{id}"} do
      result = Schedules.run(s, System.system_time(:millisecond))
      broadcast()
      result
    end
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :look, Keyword.get(opts, :first_ms, 30_000))
    {:ok, %{running: MapSet.new()}}
  end

  @impl true
  def handle_info(:look, state) do
    Process.send_after(self(), :look, 60_000)
    now = System.system_time(:millisecond)

    state =
      case Schedules.list() do
        {:ok, list} ->
          Enum.reduce(list, state, fn s, st ->
            case Schedules.due(s, now) do
              {:due, instant} ->
                if MapSet.member?(st.running, s.id) do
                  st
                else
                  me = self()
                  Task.start(fn -> send(me, {:ran, s.id, Schedules.run(s, instant), s.name}) end)
                  %{st | running: MapSet.put(st.running, s.id)}
                end

              :no ->
                st
            end
          end)

        {:error, _} ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:ran, id, result, name}, state) do
    case result do
      {:ok, saved} -> Logger.info("scheduled writeup #{name}: #{saved.url}", event: "writeup.scheduled", schedule: id)
      {:error, e} -> Logger.warning("scheduled writeup #{name} failed: #{e}", event: "writeup.schedule_failed", schedule: id, reason: e)
    end

    broadcast()
    {:noreply, %{state | running: MapSet.delete(state.running, id)}}
  end

  @doc false
  def broadcast do
    with {:ok, l} <- Schedules.list(), do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, ObsFactor.Tape.topic(), {:writeup_schedules, l})
    with {:ok, l} <- ObsFactor.Writeup.list(), do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, ObsFactor.Tape.topic(), {:writeups, l})
  end
end
