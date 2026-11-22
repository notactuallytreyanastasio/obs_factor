defmodule ObsFactorWeb.ActionsChannel do
  @moduledoc """
  `actions`: a relay. Whatever is broadcast on `ObsFactor.PubSub` topic
  `"actions"` as `{:action, map}` is pushed to every viewer as an `action`
  event with that map, so everyone sees what anyone asked for and what
  came of it. The join reply is `%{}`; nothing is kept here.
  """
  use ObsFactorWeb, :channel

  @impl true
  def join("actions", _params, socket), do: {:ok, %{}, socket}

  @impl true
  def handle_info({:action, payload}, socket) when is_map(payload) do
    push(socket, "action", payload)
    {:noreply, socket}
  end
end
