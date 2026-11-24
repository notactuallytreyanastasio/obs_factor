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
    # a shared writeup: the slug is the permission (ObsFactorWeb.WriteupController)
    get "/w/:slug", WriteupController, :shared
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

  # what scripts read: a bearer token with the scope, or the page's session
  pipeline :writeups_read do
    plug ObsFactorWeb.Plugs.TokenOrSession, scope: "writeups:read"
  end

  scope "/api", ObsFactorWeb do
    pipe_through [:browser, :writeups_read]

    get "/writeup.md", WriteupController, :build
  end

  scope "/api", ObsFactorWeb do
    pipe_through [:browser, :api_gate]

    get "/snapshot", ApiController, :snapshot
    get "/history", ApiController, :history
    get "/beam", ApiController, :beam
    get "/stream", StreamController, :stream
    get "/socket_token", SocketTokenController, :show
    post "/builds", BuildsController, :create
    get "/builds/:id", BuildsController, :show
    get "/builds/:id/log", BuildsController, :log
    get "/logs", ApiController, :logs
    get "/objectives", ObjectivesController, :index
    post "/objectives", ObjectivesController, :create
    post "/objectives/:id", ObjectivesController, :update
    get "/nodes/:id/observer/*path", ObserverController, :read
    post "/nodes/:id/observer/*path", ObserverController, :act
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
