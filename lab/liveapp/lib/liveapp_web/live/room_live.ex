defmodule LiveappWeb.RoomLive do
  use Phoenix.LiveView

  require Logger

  # A door that is knocked on this often is worth a line in the log.
  @loud 5

  def mount(_params, _session, socket), do: {:ok, assign(socket, knocks: 0)}

  def handle_params(%{"id" => id}, _uri, socket), do: {:noreply, assign(socket, id: id)}

  def render(assigns) do
    ~H"""
    <h1>Room {@id}</h1>
    <p class="big" id="knocks">{@knocks}</p>
    <button phx-click="knock">knock</button>
    <.link patch={"/room/#{@id}-annex"}>to the annex</.link>
    """
  end

  def handle_event("knock", _params, socket) do
    knocks = socket.assigns.knocks + 1

    # In this LiveView's process: the report attributes both to this page
    # (a `by` row on the custom stream, and `by` on the logged event).
    FactoryReport.event("room.knock")

    if rem(knocks, @loud) == 0 do
      Logger.warning("room #{socket.assigns.id}: #{knocks} knocks and nobody answers")
    end

    {:noreply, assign(socket, knocks: knocks)}
  end
end
