defmodule LiveappWeb.CounterLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, count: 0)}

  def render(assigns) do
    ~H"""
    <h1>Counter</h1>
    <p class="big" id="count">{@count}</p>
    <button phx-click="inc">+1</button>
    <button phx-click="reset">reset</button>
    """
  end

  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
  def handle_event("reset", _params, socket), do: {:noreply, assign(socket, count: 0)}
end
