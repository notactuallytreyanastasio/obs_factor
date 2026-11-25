defmodule ObsFactor.Writeup.Scheduler do
  @moduledoc """
  Scheduled writeups, from the page: run one now, and tell the page.

  The schedule itself is Oban's (`ObsFactor.Jobs.ScheduleTick`, every
  minute, and `ObsFactor.Jobs.ScheduledWriteup`, one per run). This module
  is what both use to broadcast the schedules and the writeups on the
  `tape` topic when a run ends, so the Write up panel shows the result.
  """

  alias ObsFactor.Writeup.Schedules

  @doc """
  Run one schedule now, for the period that ends now, in the caller (the
  page waits for the writeup). Its webhook is a job when Oban runs.
  `{:ok, saved}` or `{:error, reason}`.
  """
  def run_now(id) do
    with {:ok, s} <- Schedules.get(id) do
      opts =
        if ObsFactor.Jobs.enabled?(),
          do: [post: ObsFactor.Jobs.Webhook.enqueue_for(:schedule, id)],
          else: []

      result = Schedules.run(s, System.system_time(:millisecond), opts)
      broadcast()
      result
    end
  end

  @doc false
  def broadcast do
    with {:ok, l} <- Schedules.list(),
         do:
           Phoenix.PubSub.broadcast(
             ObsFactor.PubSub,
             ObsFactor.Tape.topic(),
             {:writeup_schedules, l}
           )

    with {:ok, l} <- ObsFactor.Writeup.list(),
         do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, ObsFactor.Tape.topic(), {:writeups, l})
  end
end
