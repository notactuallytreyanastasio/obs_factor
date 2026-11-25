defmodule ObsFactor.Jobs.Rollup do
  @moduledoc """
  Cron, every 5 minutes: roll up the hours that are over and have no row,
  oldest first, and delete rows past 13 months (`ObsFactor.Rollups.run/3`).
  The first run after a start catches up on everything the tape still has.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 240, states: :incomplete]

  require Logger

  @keep_months 13

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case ObsFactor.Rollups.run(
           System.system_time(:millisecond),
           ObsFactor.Tape.db(),
           @keep_months
         ) do
      {:ok, %{rolled: rolled, pruned: pruned}} ->
        if rolled != [] or pruned > 0,
          do:
            Logger.info(
              "rollups: #{length(rolled)} hours rolled up, #{pruned} past #{@keep_months} months deleted",
              event: "rollups.rolled",
              hours: length(rolled),
              pruned: pruned
            )

        {:ok, %{rolled: length(rolled), pruned: pruned}}

      {:error, e} ->
        {:error, ObsFactor.Tape.message(e)}
    end
  end
end
