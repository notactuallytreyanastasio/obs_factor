import Config

# PORT: the app (default 4000). FACTORY_REPORT_PORT: the report (default
# 9568), read in Liveapp.Application. FACTORY_REPORT_TOKEN: optional.
config :liveapp, LiveappWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  # A lab toy with nothing to protect: a fixed key unless one is given.
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "obslab-liveapp-not-a-secret-obslab-liveapp-not-a-secret-obslab-liveapp"
