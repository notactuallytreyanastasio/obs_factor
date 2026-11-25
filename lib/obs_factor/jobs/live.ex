defmodule ObsFactor.Jobs.Live do
  @moduledoc """
  The Oban tab, live: `{:jobs_view, view}` on topic `"jobs"`
  (`ObsFactor.Jobs.View.view/1`), while someone has the tab open.

  Oban's telemetry (a job inserted, started, stopped, raised, cancelled,
  retried, deleted, staged, pruned or rescued) marks the view dirty, as does
  `touch/0` after a page action Oban emits nothing for (pausing a queue),, and a dirty view is sent at most once every
  `every_ms` (1.5 s). It is also sent every 10 s anyway, so a scheduled job
  that became available and the cron's next run stay current. Nothing is
  read while nobody is subscribed.
  """
  use GenServer

  @topic "jobs"
  @every_ms 1_500
  @idle_ms 10_000
  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:oban, :engine, :insert_job, :stop],
    [:oban, :engine, :cancel_job, :stop],
    [:oban, :engine, :retry_job, :stop],
    [:oban, :engine, :delete_job, :stop],
    [:oban, :engine, :insert_all_jobs, :stop],
    [:oban, :engine, :stage_jobs, :stop],
    [:oban, :engine, :prune_jobs, :stop],
    [:oban, :engine, :rescue_jobs, :stop]
  ]

  def topic, do: @topic

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Something changed (an action from the page): send the view soon."
  def touch, do: if(pid = Process.whereis(__MODULE__), do: send(pid, :dirty))

  @impl true
  def init(opts) do
    :telemetry.detach({__MODULE__, :events})
    :ok = :telemetry.attach_many({__MODULE__, :events}, @events, &__MODULE__.handle_event/4, nil)
    Process.send_after(self(), :tick, Keyword.get(opts, :every_ms, @every_ms))
    {:ok, %{dirty: true, sent_at: 0, every_ms: Keyword.get(opts, :every_ms, @every_ms)}}
  end

  @doc false
  # in the job's own process: one message, never a raise
  def handle_event(_event, _measurements, _meta, _config) do
    touch()
  catch
    _, _ -> :ok
  end

  @impl true
  def handle_info(:dirty, state), do: {:noreply, %{state | dirty: true}}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.every_ms)
    now = System.monotonic_time(:millisecond)

    if watched?() and (state.dirty or now - state.sent_at >= @idle_ms) do
      case ObsFactor.Jobs.View.view() do
        {:ok, v} -> Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:jobs_view, v})
        {:error, e} -> Phoenix.PubSub.broadcast(ObsFactor.PubSub, @topic, {:jobs_error, e})
      end

      {:noreply, %{state | dirty: false, sent_at: now}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_, _), do: :telemetry.detach({__MODULE__, :events})

  defp watched?, do: Registry.lookup(ObsFactor.PubSub, @topic) != []
end
