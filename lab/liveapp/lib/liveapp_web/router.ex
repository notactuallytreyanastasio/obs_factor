defmodule LiveappWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LiveappWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # Outside the browser pipeline: a probe has no session to fetch.
  get("/health", LiveappWeb.HealthController, :show)

  scope "/", LiveappWeb do
    pipe_through(:browser)

    live("/", CounterLive)
    live("/clock", ClockLive)
    live("/room/:id", RoomLive)
  end
end
