defmodule ObsFactor.Builder.Config do
  @moduledoc """
  The builder's settings, from the environment (config/runtime.exs). Every
  one is required when OBS_ROLE=builder; a missing one stops the boot with
  its name.

  | var | meaning | lab |
  |---|---|---|
  | `BUILDER_TOKEN` | bearer token the observer sends | `obslab-builder` |
  | `BUILDER_STATE_DIR` | jobs, clones, secrets, the DNS hosts file, Caddy snippets | `lab/built` |
  | `BUILDER_DOMAIN` | apps are `<name>.<domain>` | `lab.test` |
  | `BUILDER_A_RECORD` | the address every app name points at (the box) | `127.0.0.1` |
  | `BUILDER_DNS_SERVER` | where to check the A record answers, `host:port` (for Cloudflare, one of the zone's nameservers) | `127.0.0.1:15353` |
  | `BUILDER_DNS_PROVIDER` | optional: `hosts` (default) or `cloudflare`, see `ObsFactor.Builder.Name` | `hosts` |
  | `BUILDER_CF_API_TOKEN` | with `cloudflare`: an API token with Zone > DNS > Edit on the zone; never logged | |
  | `BUILDER_CF_ZONE_ID` | with `cloudflare`: the zone id (the zone's overview page, right column) | |
  | `BUILDER_CF_PROXIED` | optional, with `cloudflare`: `true` for the orange cloud (default `false`) | |
  | `BUILDER_CF_API` | optional: the API base, for tests (default `https://api.cloudflare.com/client/v4`) | |
  | `BUILDER_CADDY_CONTAINER` | the Caddy to reload | `obslab-caddy-1` |
  | `BUILDER_CADDY_HTTP` | Caddy's HTTP listener, for checking a route answers | `http://127.0.0.1:18080` |
  | `BUILDER_SITE_PREFIX` | prefix of each site address (`http://` in the lab, none for automatic HTTPS) | `http://` |
  | `BUILDER_NETWORK` | the Docker network Caddy and the apps share | `obslab_default` |
  | `BUILDER_LLM_URL` | base URL of an OpenAI-compatible chat completions API (`/chat/completions` is appended) | `https://api.deepseek.com` |
  | `BUILDER_LLM_KEY` | its bearer key; never logged | DeepSeek's |
  | `BUILDER_LLM_MODEL` | the model | `deepseek-flash` |
  | `BUILDER_BUILDX` | optional: the buildx plugin binary, when `docker buildx` is not wired up | Homebrew's `docker-buildx` |
  """

  @keys [
    token: "BUILDER_TOKEN",
    state_dir: "BUILDER_STATE_DIR",
    domain: "BUILDER_DOMAIN",
    a_record: "BUILDER_A_RECORD",
    dns_server: "BUILDER_DNS_SERVER",
    caddy_container: "BUILDER_CADDY_CONTAINER",
    caddy_http: "BUILDER_CADDY_HTTP",
    site_prefix: "BUILDER_SITE_PREFIX",
    network: "BUILDER_NETWORK",
    llm_url: "BUILDER_LLM_URL",
    llm_key: "BUILDER_LLM_KEY",
    llm_model: "BUILDER_LLM_MODEL",
    buildx: "BUILDER_BUILDX",
    dns_provider: "BUILDER_DNS_PROVIDER",
    cf_api_token: "BUILDER_CF_API_TOKEN",
    cf_zone_id: "BUILDER_CF_ZONE_ID",
    cf_api: "BUILDER_CF_API",
    cf_proxied: "BUILDER_CF_PROXIED"
  ]

  @optional [:site_prefix, :buildx, :dns_provider, :cf_api_token, :cf_zone_id, :cf_api, :cf_proxied]

  def keys, do: @keys

  def load! do
    cfg = Application.get_env(:obs_factor, :builder, [])

    provider = cfg[:dns_provider] || "hosts"

    unless provider in ["hosts", "cloudflare"] do
      raise ArgumentError, "BUILDER_DNS_PROVIDER is #{inspect(provider)}; it takes hosts or cloudflare"
    end

    required = if provider == "cloudflare", do: [:cf_api_token, :cf_zone_id], else: []
    missing = for {k, var} <- @keys, cfg[k] == nil, k not in @optional or k in required, do: var

    if missing != [] do
      raise ArgumentError,
            "OBS_ROLE=builder needs #{Enum.join(missing, ", ")} (see ObsFactor.Builder.Config)"
    end

    state_dir = Path.expand(cfg[:state_dir])
    {:ok, a} = :inet.parse_ipv4_address(to_charlist(cfg[:a_record]))
    [host, port] = String.split(cfg[:dns_server], ":")

    # A name is resolved once, at boot: Cloudflare gives each zone its
    # nameservers by name (e.g. ada.ns.cloudflare.com).
    dns_ip =
      case :inet.getaddr(to_charlist(host), :inet) do
        {:ok, ip} -> ip
        {:error, why} -> raise ArgumentError, "BUILDER_DNS_SERVER #{host}: #{:inet.format_error(why)}"
      end

    %{
      token: cfg[:token],
      state_dir: state_dir,
      domain: cfg[:domain],
      a_record: a,
      a_record_text: cfg[:a_record],
      dns_server: {dns_ip, String.to_integer(port)},
      hosts_file: Path.join([state_dir, "dns", "hosts"]),
      caddy_dir: Path.join(state_dir, "caddy"),
      jobs_dir: Path.join(state_dir, "jobs"),
      apps_dir: Path.join(state_dir, "apps"),
      caddy_container: cfg[:caddy_container],
      caddy_http: cfg[:caddy_http],
      site_prefix: cfg[:site_prefix] || "",
      network: cfg[:network],
      llm: %{url: String.trim_trailing(cfg[:llm_url], "/"), key: cfg[:llm_key], model: cfg[:llm_model]},
      buildx: cfg[:buildx],
      dns_provider: provider,
      cf: %{token: cfg[:cf_api_token], zone: cfg[:cf_zone_id], api: cfg[:cf_api], proxied: cfg[:cf_proxied] == "true"}
    }
  end
end
