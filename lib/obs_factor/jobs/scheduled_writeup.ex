defmodule ObsFactor.Jobs.ScheduledWriteup do
  @moduledoc """
  One scheduled writeup: `%{"id" => schedule, "instant" => unix ms}`, the
  period ending at that instant (`ObsFactor.Writeup.Schedules.run/3`).

  Three attempts: a writeup that could not be built (Postgres away, a
  statement timeout on a week's tape) is tried again. Its webhook is not
  posted from here: it is a `ObsFactor.Jobs.Webhook` of its own, so a Slack
  that is down is retried without writing the writeup twice. A schedule
  deleted in the meantime cancels the job.
  """
  use Oban.Worker,
    queue: :writeups,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:id, :instant]]

  alias ObsFactor.Jobs.Webhook
  alias ObsFactor.Writeup.{Scheduler, Schedules}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id, "instant" => instant}}) do
    case Schedules.get(id) do
      {:ok, s} ->
        result = Schedules.run(s, instant, post: Webhook.enqueue_for(:schedule, id))
        Scheduler.broadcast()

        case result do
          {:ok, saved} -> {:ok, %{slug: saved.slug}}
          # written, but its webhook could not even be enqueued: not again
          {:error, "written, but" <> _ = e} -> {:cancel, e}
          {:error, e} -> {:error, e}
        end

      {:error, "no schedule" <> _ = e} ->
        {:cancel, e}

      {:error, e} ->
        {:error, ObsFactor.Tape.message(e)}
    end
  end
end
