defmodule ObsFactor.Sources do
  @moduledoc """
  The latest result of every collector, in a public ETS table so that building
  a snapshot never waits on a collector that is busy polling.

  An entry is `%{ok, at, error, data, attempted_at, max_age_ms}`:
  `at` is the last *successful* read (nil if never), `data` is the result of
  the last attempt and is nil whenever that attempt failed. Stale numbers are
  never served as current.
  """

  @table __MODULE__
  @names [:docker, :caddy, :postgres, :host, :probes, :sites, :access, :reports,
          # deploys (ObsFactor.Deploys): the .deployed files
          :deploys]

  # :builder only exists when the observer is pointed at a builder
  # (BUILDER_URL): a box without one has nothing to report as failing.
  def names do
    if Application.get_env(:obs_factor, :builder_client, [])[:url],
      do: @names ++ [:builder],
      else: @names
  end

  def create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  def put(name, entry) when name in @names or name == :builder do
    :ets.insert(@table, {name, entry})
    :ok
  end

  @doc "All sources as the snapshot builder wants them, checked for staleness."
  def all(now_ms \\ System.system_time(:millisecond)) do
    Map.new(names(), fn name -> {name, get(name, now_ms)} end)
  end

  def get(name, now_ms \\ System.system_time(:millisecond)) do
    case :ets.lookup(@table, name) do
      [] ->
        %{ok: false, at: nil, error: "no result yet", data: nil}

      [{^name, entry}] ->
        age = now_ms - entry.attempted_at

        if age > entry.max_age_ms do
          %{
            ok: false,
            at: entry.at,
            error: "no result for #{div(age, 1000)} s (collector stuck or dead)",
            data: nil
          }
        else
          Map.take(entry, [:ok, :at, :error, :data])
        end
    end
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end
end
