defmodule ObsFactor.Jobs do
  @moduledoc """
  Oban, in the observer: the work that used to be a GenServer with a timer.

  | queue | worker | when |
  |---|---|---|
  | `writeups` | `ObsFactor.Jobs.ScheduleTick` | cron, every minute: enqueues the scheduled writeups that are due |
  | `writeups` | `ObsFactor.Jobs.ScheduledWriteup` | one per schedule and instant (unique), 3 attempts |
  | `maintenance` | `ObsFactor.Jobs.Rollup` | cron, every 5 minutes: hourly rollups and their pruning |
  | `webhooks` | `ObsFactor.Jobs.Webhook` | an alert or a scheduled writeup's post, 5 attempts with backoff |

  What is not here, and why: the tape's thinning, the SLO evaluation, the
  alerts engine and the objectives probe hold state between runs (the last
  frame, what was already sent), so they stay processes.

  ## Running it

  Only with OBJECTIVES_PG_URL (`child_specs(nil)` is `[]`), on
  `ObsFactor.Repo`, a pool of two in that database. The notifier is
  `Oban.Notifiers.PG` (Erlang process groups, no LISTEN connection) and the
  peer `Oban.Peers.Global`: one observer, no extra connection either, so
  the role needs four connections in all (deploy/objectives-db.sql).

  Plugins: `Oban.Plugins.Cron` (the table above), `Oban.Plugins.Pruner`
  (finished jobs kept 7 days, so the Oban tab has a week of history),
  `Oban.Plugins.Lifeline` (a job left `executing` by a restart is rescued
  after 30 minutes).

  The board's Oban tab (`ObsFactor.Jobs.View`, `ObsFactorWeb.JobsChannel`)
  shows all of it, and lets an operator retry, cancel, delete, pause a
  queue and run a cron entry now.
  """

  @queues [writeups: 2, maintenance: 1, webhooks: 3]
  @crontab [
    {"* * * * *", ObsFactor.Jobs.ScheduleTick},
    {"*/5 * * * *", ObsFactor.Jobs.Rollup}
  ]

  def queues, do: @queues
  def crontab, do: @crontab

  @doc "The repo, the migrations and Oban for a postgres:// URL; nothing when it is nil."
  def child_specs(nil), do: []

  def child_specs(url) do
    [
      {ObsFactor.Repo, repo_opts(url)},
      ObsFactor.Jobs.Migrate,
      {Oban, config()},
      ObsFactor.Jobs.Live
    ]
  end

  def repo_opts(url, extra \\ []) do
    ObsFactor.Postgres.opts(url,
      name: nil,
      pool_size: 2,
      statement_timeout: "15000",
      application_name: "obs_factor jobs"
    )
    |> Keyword.delete(:name)
    |> Keyword.merge(log: false)
    |> Keyword.merge(extra)
  end

  def config(extra \\ []) do
    Keyword.merge(
      [
        repo: ObsFactor.Repo,
        notifier: Oban.Notifiers.PG,
        peer: Oban.Peers.Global,
        queues: @queues,
        plugins: [
          {Oban.Plugins.Cron, crontab: @crontab},
          {Oban.Plugins.Pruner, max_age: 7 * 86_400},
          {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
        ]
      ],
      extra
    )
  end

  @doc "Is Oban running in this observer?"
  def enabled?, do: Oban.whereis(Oban) != nil

  @doc "Insert a job when Oban runs: `{:ok, job}`, else `{:error, \"no jobs\"}`."
  def insert(changeset) do
    if enabled?(),
      do: Oban.insert(changeset),
      else: {:error, "no jobs: OBJECTIVES_PG_URL is not set"}
  end
end
