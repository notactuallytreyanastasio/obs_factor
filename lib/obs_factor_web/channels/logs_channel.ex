defmodule ObsFactorWeb.LogsChannel do
  @moduledoc """
  `logs`: the observer's log ring (`ObsFactor.LogRing`), tailed.

  Join with `%{after: id}` (0 or absent: everything kept). The reply is
  `%{events: [...], last_id: id, kept: 2000}`, every event with an id above
  `after`, oldest first; then an `events` push (`%{events: [event]}`) for
  each new one. Events logged between the reply and the live subscription
  are pushed once it is in place, so a client that keeps `last_id` and
  rejoins with it after a reconnect misses nothing the ring still holds;
  an event may arrive twice around a join, and ids are unique, so dedupe
  on `id`.
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.LogRing

  @impl true
  def join("logs", params, socket) do
    case after_id(params) do
      {:ok, after_id} ->
        events = LogRing.since(after_id)
        last = (List.last(events) || %{id: after_id}).id
        send(self(), :after_join)

        {:ok, %{events: events, last_id: last, kept: LogRing.keep()},
         assign(socket, :last_id, last)}

      :error ->
        ObsFactorWeb.Log.refuse("after must be a non-negative integer")
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    case LogRing.since(socket.assigns.last_id) do
      [] -> :ok
      events -> push(socket, "events", %{events: events})
    end

    {:noreply, socket}
  end

  def handle_info({:log, event}, socket) do
    push(socket, "events", %{events: [event]})
    {:noreply, socket}
  end

  defp after_id(%{"after" => n}) when is_integer(n) and n >= 0, do: {:ok, n}
  defp after_id(%{"after" => nil}), do: {:ok, 0}
  defp after_id(%{"after" => _}), do: :error
  defp after_id(_), do: {:ok, 0}
end
