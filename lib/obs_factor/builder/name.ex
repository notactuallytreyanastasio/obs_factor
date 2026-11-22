defmodule ObsFactor.Builder.Name do
  @moduledoc """
  Primitive 1, the name: an A record `<name>.<domain> -> <box>`, written by
  one of two providers (`BUILDER_DNS_PROVIDER`):

  - `hosts` (the lab, default): a hosts file that CoreDNS serves
    (`lab/dns/Corefile`, reloaded every 2 s), so the record is real DNS:
    `dig +tcp @127.0.0.1 -p 15353 <name>.lab.test`.
  - `cloudflare`: Cloudflare's v4 DNS API on the zone `BUILDER_CF_ZONE_ID`,
    with an API token that has Zone > DNS > Edit on it.

  Either way the builder only touches records it wrote. A hosts line is
  marked `# obs_factor name=<name>`; a Cloudflare record carries the same
  marker in its `comment` field. Any other record for the hostname, of any
  type, means the name is taken, and the step fails rather than overwrite it.

  The step is done when `BUILDER_DNS_SERVER` answers with the record. For
  Cloudflare, point that at one of the zone's own nameservers (the two
  `*.ns.cloudflare.com` names on the zone's overview page), not 1.1.1.1 or
  8.8.8.8: a public resolver that was asked for the name before it existed
  caches the NXDOMAIN for the zone's negative TTL, up to 30 minutes, and the
  check would wait out that cache instead of checking Cloudflare.

  Proxied records (`BUILDER_CF_PROXIED=true`, the orange cloud) answer with
  Cloudflare's addresses, not the box's, so the check then accepts any A
  answer. Off by default: Caddy gets its certificate with the HTTP-01
  challenge, which needs requests for the name to reach the box.
  """

  @cf_api "https://api.cloudflare.com/client/v4"

  def ensure_file!(%{dns_provider: "hosts"} = cfg) do
    File.mkdir_p!(Path.dirname(cfg.hosts_file))

    unless File.exists?(cfg.hosts_file) do
      File.write!(cfg.hosts_file, "# A records for apps built by obs_factor. The builder rewrites its own lines.\n")
    end
  end

  def ensure_file!(_cfg), do: :ok

  def fqdn(cfg, name), do: "#{name}.#{cfg.domain}"

  defp marker(name), do: "obs_factor name=#{name} "

  @doc "Writes the record and waits until the DNS server answers with it."
  def put(cfg, name, job_id, log) do
    with :ok <- write(cfg, name, job_id, log), do: wait_answer(cfg, fqdn(cfg, name), log, 60)
  end

  @doc "Writes the record with the provider; `:ok` or `{:error, why}`."
  def write(%{dns_provider: "hosts"} = cfg, name, job_id, log) do
    fqdn = fqdn(cfg, name)
    lines = cfg.hosts_file |> File.read!() |> String.split("\n", trim: true)
    marker = "# " <> marker(name)

    foreign =
      Enum.find(lines, fn l ->
        not String.starts_with?(l, "#") and fqdn in (l |> String.split("#") |> hd() |> String.split()) and
          not String.contains?(l, marker)
      end)

    if foreign do
      {:error, "#{fqdn} is already in DNS and the builder did not write it: #{inspect(foreign)}"}
    else
      record = "#{cfg.a_record_text} #{fqdn} #{marker}job=#{job_id}"
      kept = Enum.reject(lines, &String.contains?(&1, marker))
      write_atomic!(cfg.hosts_file, Enum.join(kept ++ [record], "\n") <> "\n")
      log.("A #{fqdn} -> #{cfg.a_record_text} written to #{cfg.hosts_file}")
      :ok
    end
  end

  def write(%{dns_provider: "cloudflare", cf: cf} = cfg, name, job_id, log) do
    fqdn = fqdn(cfg, name)

    body = %{
      type: "A",
      name: fqdn,
      content: cfg.a_record_text,
      proxied: cf.proxied,
      # 1 is "automatic", the only TTL a proxied record takes.
      ttl: if(cf.proxied, do: 1, else: 60),
      comment: marker(name) <> "job=#{job_id}"
    }

    with {:ok, records} <- cf_records(cf, fqdn),
         {:ok, verb} <- cf_write(cf, fqdn, name, records, body) do
      log.("Cloudflare: #{verb} A #{fqdn} -> #{cfg.a_record_text}#{if cf.proxied, do: " (proxied)", else: ""}")
      :ok
    end
  end

  def delete(%{dns_provider: "hosts"} = cfg, name) do
    marker = "# " <> marker(name)
    lines = cfg.hosts_file |> File.read!() |> String.split("\n", trim: true)
    write_atomic!(cfg.hosts_file, Enum.join(Enum.reject(lines, &String.contains?(&1, marker)), "\n") <> "\n")
  end

  # Only records carrying our marker; anything else under the name stays.
  def delete(%{dns_provider: "cloudflare", cf: cf} = cfg, name) do
    with {:ok, records} <- cf_records(cf, fqdn(cfg, name)) do
      for r <- records, ours?(r, name), do: {:ok, _} = cf_req(cf, :delete, "/dns_records/#{r["id"]}", nil)
      :ok
    end
  end

  defp ours?(r, name), do: String.starts_with?(r["comment"] || "", marker(name))

  # Every record under the exact name, any type: a CNAME or AAAA someone
  # else made takes the name just as an A does.
  defp cf_records(cf, fqdn) do
    cf_req(cf, :get, "/dns_records", nil, params: [name: fqdn, per_page: 100])
  end

  defp cf_write(cf, fqdn, name, records, body) do
    case Enum.split_with(records, &ours?(&1, name)) do
      {_, [r | _]} ->
        {:error, "#{fqdn} is already in Cloudflare and the builder did not make it: #{r["type"]} #{r["content"]} (comment #{inspect(r["comment"])})"}

      {[], []} ->
        with {:ok, _} <- cf_req(cf, :post, "/dns_records", body), do: {:ok, "created"}

      {[r | extra], []} ->
        for x <- extra, do: {:ok, _} = cf_req(cf, :delete, "/dns_records/#{x["id"]}", nil)

        if r["type"] == "A" do
          with {:ok, _} <- cf_req(cf, :patch, "/dns_records/#{r["id"]}", body), do: {:ok, "updated"}
        else
          with {:ok, _} <- cf_req(cf, :delete, "/dns_records/#{r["id"]}", nil),
               {:ok, _} <- cf_req(cf, :post, "/dns_records", body),
               do: {:ok, "replaced"}
        end
    end
  end

  # Cloudflare answers {success, errors: [{code, message}], result}. A
  # failure carries its codes and messages; the token never appears.
  defp cf_req(cf, method, path, body, opts \\ []) do
    req =
      [method: method, url: (cf.api || @cf_api) <> "/zones/#{cf.zone}" <> path, auth: {:bearer, cf.token}, retry: :transient, max_retries: 2, receive_timeout: 20_000]
      |> Keyword.merge(opts)
      |> then(&if(body, do: Keyword.put(&1, :json, body), else: &1))

    case Req.request(req) do
      {:ok, %Req.Response{status: s, body: %{"success" => true, "result" => result}}} when s in 200..299 ->
        {:ok, result}

      {:ok, %Req.Response{status: s, body: %{"errors" => errs}}} ->
        {:error, "Cloudflare #{method |> to_string() |> String.upcase()} #{path} answered #{s}: " <> Enum.map_join(errs, "; ", &"#{&1["code"]} #{&1["message"]}")}

      {:ok, %Req.Response{status: s, body: b}} ->
        {:error, "Cloudflare #{path} answered #{s}: #{inspect(b) |> String.slice(0, 200)}"}

      {:error, e} ->
        {:error, "Cloudflare #{path}: #{Exception.message(e)}"}
    end
  end

  @doc "The A records the DNS server gives for `fqdn` right now."
  # Over TCP: Colima forwards published ports for TCP only, so a UDP query
  # to the lab's 127.0.0.1:15353 times out (verified). TCP is a plain DNS
  # transport every server speaks, so the check holds for production too.
  def lookup(cfg, fqdn) do
    :inet_res.lookup(to_charlist(fqdn), :in, :a, nameservers: [cfg.dns_server], timeout: 2_000, retry: 1, usevc: true)
  end

  defp wait_answer(cfg, fqdn, log, tries) do
    proxied = cfg.dns_provider == "cloudflare" and cfg.cf.proxied

    case lookup(cfg, fqdn) do
      [ip | _] when ip == cfg.a_record or proxied ->
        {dns_ip, port} = cfg.dns_server
        log.("dig +tcp @#{:inet.ntoa(dns_ip)} -p #{port} #{fqdn}: #{:inet.ntoa(ip)}")
        {:ok, "#{fqdn} A #{:inet.ntoa(ip)}"}

      _ when tries > 0 ->
        Process.sleep(1_000)
        wait_answer(cfg, fqdn, log, tries - 1)

      other ->
        {:error, "DNS server never answered #{fqdn} with #{cfg.a_record_text} (last answer: #{inspect(other)})"}
    end
  end

  # Rename over the old file: CoreDNS never reads a half-written one.
  defp write_atomic!(path, content) do
    tmp = path <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end
end
