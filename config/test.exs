import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :obs_factor, ObsFactorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xvpBrGj6NUQh5zRomvdqqORC2VLzbzm/xK7rpQt+tDb2okyR68Rv+/iRcxkiG+Mk",
  server: false

# Tests drive the snapshot builder and the store directly; no collector polls
# anything and no Postgres connection is opened.
config :obs_factor,
  start_collectors: false,
  topology_path: "test/support/topology.exs",
  password: "correct horse battery staple",
  sources: []

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Feeds stop this long after their last subscriber (10 s outside tests).
config :obs_factor, feeds_linger_ms: 150
