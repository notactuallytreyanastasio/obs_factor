defmodule LiveappWeb.ClockLive do
  use Phoenix.LiveView

  @tick 1_000

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick)
    {:ok, assign(socket, now: now(), ticks: 0)}
  end

  def render(assigns) do
    ~H"""
    <h1>Clock</h1>
    <p class="big" id="now">{@now}</p>
    <p>{@ticks} ticks since this page connected</p>
    """
  end

  def handle_info(:tick, socket) do
    started = System.monotonic_time()
    Process.send_after(self(), :tick, @tick)
    socket = socket |> assign(now: now()) |> update(:ticks, &(&1 + 1))

    # Something only this app knows happened: a `custom` stream in its report.
    FactoryReport.event("clock.tick", duration: System.monotonic_time() - started)
    {:noreply, socket}
  end

  defp now, do: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")
end
