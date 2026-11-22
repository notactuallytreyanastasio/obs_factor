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

  pipeline :builder_api do
    plug :accepts, ["json"]
    plug ObsFactorWeb.Plugs.BuilderToken
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
    get "/beam", ApiController, :beam
    get "/stream", StreamController, :stream
    post "/builds", BuildsController, :create
    get "/builds/:id", BuildsController, :show
    get "/builds/:id/log", BuildsController, :log
    get "/logs", ApiController, :logs
  end

  # OBS_ROLE=builder only; the plug answers 404 on the observer.
  scope "/builder/api", ObsFactorWeb do
    pipe_through :builder_api

    get "/jobs", BuilderController, :index
    post "/jobs", BuilderController, :create
    get "/jobs/:id", BuilderController, :show
    get "/jobs/:id/log", BuilderController, :log
  end
end
