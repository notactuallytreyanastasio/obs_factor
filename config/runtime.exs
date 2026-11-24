import Config

# Runtime configuration, read from the environment for every env (see the
# Environment table in docs/contract.md). A source whose variable is unset is
# reported as failed in `sources`; it does not stop the boot. The password and,
# outside test, the topology are different: without them the app is useless or
# open, so boot fails (the topology check is in ObsFactor.Application).

if System.get_env("PHX_SERVER") do
  config :obs_factor, ObsFactorWeb.Endpoint, server: true
end

config :obs_factor, ObsFactorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

blank_to_nil = fn
  nil -> nil
  value -> if String.trim(value) == "", do: nil, else: value
end

if config_env() != :test do
  config :obs_factor, :sources,
    docker_url: blank_to_nil.(System.get_env("DOCKER_URL")),
    caddy_metrics_url: blank_to_nil.(System.get_env("CADDY_METRICS_URL")),
    pg_url: blank_to_nil.(System.get_env("PG_URL")),
    host_proc: blank_to_nil.(System.get_env("HOST_PROC")),
    host_disk_path: blank_to_nil.(System.get_env("HOST_DISK_PATH")),
    sites_dir: blank_to_nil.(System.get_env("SITES_DIR")),
    access_log: blank_to_nil.(System.get_env("ACCESS_LOG")),
    # Sent as the bearer token to every topology `report` URL when set.
    report_token: blank_to_nil.(System.get_env("REPORT_TOKEN"))

  # The bearer token the observer sends with observer actions (POST
  # /api/nodes/:id/observer/...): the apps' FACTORY_REPORT_ACTIONS_TOKEN.
  # Unset: every action answers 403, the observer's own included.
  config :obs_factor, observer_actions_token: blank_to_nil.(System.get_env("OBSERVER_ACTIONS_TOKEN"))

  # Required; ObsFactor.Application refuses to start without it.
  config :obs_factor, topology_path: blank_to_nil.(System.get_env("TOPOLOGY"))

  # Mission objectives (ObsFactor.Objectives): a database and a role of
  # their own, writable, unlike PG_URL's read-only monitor. Unset: no
  # objectives, the floor works as before.
  config :obs_factor, objectives_pg_url: blank_to_nil.(System.get_env("OBJECTIVES_PG_URL"))
end

# --- heartbeat (ObsFactor.Heartbeat, docs/contract.md "Heartbeat") ---
# HEARTBEAT_URL: pinged every 60 s while the observer is healthy. Unset: no
# pings. HEARTBEAT_FAIL=1 also POSTs <url>/fail when it is not.
# HEARTBEAT_METHOD=get for push URLs that only take GET.
if config_env() != :test do
  config :obs_factor, :heartbeat,
    url: blank_to_nil.(System.get_env("HEARTBEAT_URL")),
    fail: System.get_env("HEARTBEAT_FAIL") in ~w(1 true yes),
    method: if(System.get_env("HEARTBEAT_METHOD", "") |> String.downcase() == "get", do: :get, else: :post)
end
# --- end heartbeat ---

# OBS_ROLE=builder runs the builder (lib/obs_factor/builder) instead of the
# observer. The observer reads a builder at BUILDER_URL when it is set.
config :obs_factor, :role, if(System.get_env("OBS_ROLE") == "builder", do: :builder, else: :observer)

if config_env() != :test do
  config :obs_factor, :builder_client,
    url: blank_to_nil.(System.get_env("BUILDER_URL")),
    token: blank_to_nil.(System.get_env("BUILDER_TOKEN"))

  config :obs_factor,
         :builder,
         (for key <- ~w(token state_dir domain a_record dns_server caddy_container caddy_http site_prefix network llm_url llm_key llm_model buildx dns_provider cf_api_token cf_zone_id cf_api cf_proxied)a do
            {key, blank_to_nil.(System.get_env("BUILDER_" <> String.upcase(Atom.to_string(key))))}
          end)
end

password = blank_to_nil.(System.get_env("OBS_FACTOR_PASSWORD"))

cond do
  config_env() == :prod and password == nil ->
    raise """
    environment variable OBS_FACTOR_PASSWORD is missing or empty.
    The observer refuses to boot without its password.
    """

  config_env() == :test ->
    :ok

  true ->
    config :obs_factor, :password, password
end

# Which page origins may open the websocket (/socket). Unset: the endpoint's
# default, the host of PHX_HOST in prod (behind Caddy the browser's origin is
# https://PHX_HOST, and Caddy passes the Host through); dev allows any.
# Set it when the page is reached under another name, e.g. the lab's
# CHECK_ORIGIN=//localhost,//127.0.0.1 for http://127.0.0.1:14000.
case blank_to_nil.(System.get_env("CHECK_ORIGIN")) do
  nil -> :ok
  list -> config :obs_factor, ObsFactorWeb.Endpoint, check_origin: list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :obs_factor, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :obs_factor, ObsFactorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
