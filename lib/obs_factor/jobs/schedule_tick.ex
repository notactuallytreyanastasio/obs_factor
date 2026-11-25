defmodule ObsFactor.Jobs.ScheduleTick do
  @moduledoc """
  Cron, every minute: enqueue a `ObsFactor.Jobs.ScheduledWriteup` for each
  schedule that is due (`ObsFactor.Writeup.Schedules.due/2`).

  Uniqueness on (schedule, instant) is what keeps a slow run from being
  enqueued again by the next tick; a run that failed has its `last_run_at`
  stamped anyway (`Schedules.run/3`), so it is not due again either, and
  only Oban's retries run it again.
  """
  use Oban.Worker, queue: :writeups, max_attempts: 1

  alias ObsFactor.Jobs.ScheduledWriteup
  alias ObsFactor.Writeup.Schedules

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = System.system_time(:millisecond)

    with {:ok, list} <- Schedules.list() do
      enqueued =
        for s <- list, {:due, instant} <- [Schedules.due(s, now)] do
          {:ok, job} = Oban.insert(ScheduledWriteup.new(%{id: s.id, instant: instant}))
          if job.conflict?, do: nil, else: job.id
        end

      {:ok, %{enqueued: Enum.reject(enqueued, &is_nil/1)}}
    end
  end
end
