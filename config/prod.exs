import Config

# Force using SSL in production. /health is excluded: the deploy check and
# Caddy call it over plain HTTP inside the Docker network.
config :obs_factor, ObsFactorWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# The session cookie only travels over HTTPS (Caddy terminates TLS).
config :obs_factor, secure_cookie: true

# Do not print debug messages in production
config :logger, level: :info
