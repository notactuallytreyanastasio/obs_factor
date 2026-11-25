defmodule ObsFactor.Jobs.Migrate do
  @moduledoc """
  Runs the repo's migrations (Oban's tables) once at start, before Oban.

  A supervisor child that does its work in `start_link/1` and returns
  `:ignore`, so Oban, after it in the list, starts on tables that are
  there. It does not use `Ecto.Migrator` as a child because that one raises
  when Postgres does not answer, and the observer runs without its database
  (the objectives store's rule): a failed migration is logged and Oban
  starts anyway, its queries failing until Postgres is back and the
  observer restarts.
  """
  require Logger

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts) do
    repo = Keyword.get(opts, :repo, ObsFactor.Repo)

    try do
      ran =
        Ecto.Migrator.run(repo, Keyword.get(opts, :path, migrations()), :up,
          all: true,
          log: false
        )

      if ran != [], do: Logger.info("jobs: migrated #{inspect(ran)}", event: "jobs.migrated")
    rescue
      e ->
        Logger.error("jobs: migrations failed: #{Exception.message(e)}",
          event: "jobs.migrate_failed",
          reason: Exception.message(e)
        )
    catch
      :exit, why ->
        Logger.error("jobs: migrations failed: #{inspect(why)}",
          event: "jobs.migrate_failed",
          reason: inspect(why)
        )
    end

    :ignore
  end

  def migrations, do: Application.app_dir(:obs_factor, "priv/repo/migrations")
end
