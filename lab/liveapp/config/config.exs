import Config

config :liveapp, LiveappWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [html: LiveappWeb.ErrorHTML], layout: false],
  pubsub_server: Liveapp.PubSub,
  live_view: [signing_salt: "obslab-liveapp"],
  # The lab reaches it under whatever hostname lab/Caddyfile gives it.
  check_origin: false,
  server: true

# One JSON object per line on stdout, with the page a line was logged for.
config :logger, :default_handler, formatter: {FactoryReport.JSONFormatter, %{}}
config :logger, level: :info
config :phoenix, :json_library, Jason
