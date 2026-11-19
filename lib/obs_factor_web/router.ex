defmodule ObsFactorWeb.Router do
  use ObsFactorWeb, :router

  alias ObsFactorWeb.Plugs.RequireSession

  pipeline :browser do
    plug :fetch_session
  end

  pipeline :page_gate do
    plug RequireSession, on_missing: :redirect
  end

  pipeline :api_gate do
    plug RequireSession, on_missing: :json
  end

  scope "/", ObsFactorWeb do
    get "/health", HealthController, :show
  end

  scope "/", ObsFactorWeb do
    pipe_through :browser

    get "/login", AuthController, :show
    post "/login", AuthController, :create
    post "/logout", AuthController, :delete
  end

  scope "/", ObsFactorWeb do
    pipe_through [:browser, :page_gate]

    get "/", PageController, :index
  end

  scope "/api", ObsFactorWeb do
    pipe_through [:browser, :api_gate]

    get "/snapshot", ApiController, :snapshot
    get "/history", ApiController, :history
    get "/stream", StreamController, :stream
  end
end
