defmodule ObsFactorWeb.SnapshotsChannel do
  @moduledoc """
  `snapshots`: the join reply is the current snapshot
  (`%{snapshot: snapshot}`, or `%{error: reason}` before the first tick or
  when the last build failed); then a `snapshot` push per tick and an
  `error` push (`%{error: message}`) for a tick whose build failed.

  The ticker encodes each snapshot once; it is pushed as a `Jason.Fragment`,
  so the binary goes into each socket's frame without being encoded again.
  """
  use ObsFactorWeb, :channel

  @impl true
  def join("snapshots", _params, socket) do
    current = ObsFactor.Store.snapshot()
    # PubSub subscribes this process after join/3 returns: a tick between
    # the read above and that subscription is caught in :after_join
    send(self(), :after_join)
    {:ok, reply(current), assign(socket, :joined_with, current)}
  end

  @impl true
  def handle_info(:after_join, socket) do
    case ObsFactor.Store.snapshot() do
      same when same == socket.assigns.joined_with -> :ok
      {:ok, json} -> push(socket, "snapshot", Jason.Fragment.new(json))
      {:error, m} -> push(socket, "error", %{error: "snapshot build failed: " <> m})
      :none -> :ok
    end

    {:noreply, assign(socket, :joined_with, nil)}
  end

  def handle_info({:snapshot, json}, socket) do
    push(socket, "snapshot", Jason.Fragment.new(json))
    {:noreply, socket}
  end

  def handle_info({:snapshot_error, message}, socket) do
    push(socket, "error", %{error: "snapshot build failed: " <> message})
    {:noreply, socket}
  end

  defp reply({:ok, json}), do: %{snapshot: Jason.Fragment.new(json)}
  defp reply({:error, m}), do: %{error: "snapshot build failed: " <> m}
  defp reply(:none), do: %{error: "no snapshot yet"}
end
