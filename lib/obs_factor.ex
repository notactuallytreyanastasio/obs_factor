defmodule ObsFactor do
  @moduledoc """
  The observer: collectors poll the box, `ObsFactor.Ticker` joins their
  results with the topology into one snapshot per tick (docs/contract.md).
  """

  @topology_key {__MODULE__, :topology}

  @doc "The topology loaded and validated at boot."
  def topology, do: :persistent_term.get(@topology_key)

  def put_topology(topology), do: :persistent_term.put(@topology_key, topology)
end
