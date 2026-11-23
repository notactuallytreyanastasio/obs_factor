# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :obs_factor,
  generators: [timestamp_type: :utc_datetime],
  start_collectors: true,
  tick_ms: 5_000,
  sites_interval_ms: 120_000,
  password: nil,
  # Feed resolvers besides the built-in ObsFactor.Feeds.Views (ObsFactor.Feeds, "Adding a view")
  feed_views: [ObsFactor.Feeds.ObserverViews]

# Configure the endpoint
config :obs_factor, ObsFactorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ObsFactorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ObsFactor.PubSub,
  live_view: [signing_salt: "S8Im8JK7"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :event]

# Structured logs (docs/contract.md, "Logs"). Every event the app emits
# carries `event` and the fields below as Logger metadata. In prod (and so
# the lab container, which runs the prod release) stdout is one JSON object
# per line in factory_report's shape, the same as the other apps on the box:
# {"time","level","msg","app","module","request_id","page", ...these fields}.
# Dev and test keep the text formatter. ObsFactor.LogRing reads the same
# metadata for the log explorer's facets.
log_fields =
  ~w(event source node member action target args by objective_id job mode fqdn
     method path route handler transport channel topic status took_ms
     reason error previous_error kind stacktrace)a

log_formatter = {FactoryReport.JSONFormatter, %{app: "obs_factor", metadata: log_fields}}
config :obs_factor, :log_formatter, log_formatter

if config_env() == :prod do
  config :logger, :default_handler, formatter: log_formatter
end

# ObsFactorWeb.Log writes one structured event per request, socket connect
# and channel join. Phoenix's own text lines for those would be a second,
# unstructured copy of each.
config :phoenix, :logger, false

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
