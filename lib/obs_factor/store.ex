defmodule ObsFactor.Store do
  @moduledoc """
  Owns the ETS tables that outlive any one collector or tick: the source
  results (`ObsFactor.Sources`) and the latest encoded snapshot.
  """

  use GenServer

  @latest __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    ObsFactor.Sources.create_table()
    :ets.new(@latest, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "`{:ok, json}` or `{:error, message}`."
  def put_snapshot(result), do: :ets.insert(@latest, {:snapshot, result})

  @doc "`{:ok, json}`, `{:error, message}` or `:none` before the first tick."
  def snapshot do
    case :ets.lookup(@latest, :snapshot) do
      [{:snapshot, result}] -> result
      [] -> :none
    end
  end

  def clear_snapshot, do: :ets.delete(@latest, :snapshot)
end
