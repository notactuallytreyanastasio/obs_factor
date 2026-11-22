defmodule ObsFactor.Builder.Route do
  @moduledoc """
  Primitive 2, the route: one Caddy site block per app, in its own file
  (`<state>/caddy/<name>.caddy`), pulled in by `import /built/caddy/*.caddy`
  at the end of the Caddyfile. A route starts as a placeholder (the lot) and
  becomes a `reverse_proxy` once the service answers.

  Caddy is reloaded with `docker exec <caddy> caddy reload`, which goes
  through Caddy's own admin endpoint inside its container: nothing new is
  exposed. A reload Caddy rejects (a duplicate hostname, a bad directive)
  puts the previous file back and reloads again, so one bad app never takes
  the other sites down.
  """

  alias ObsFactor.Builder.Shell

  @lot_header "X-Obs-Factor-Lot"

  def path(cfg, name), do: Path.join(cfg.caddy_dir, "#{name}.caddy")

  def placeholder(cfg, name, fqdn, job_id, text) do
    """
    # obs_factor build #{job_id}: the lot for #{fqdn}. Written by the builder.
    #{cfg.site_prefix}#{fqdn} {
    \theader #{@lot_header} #{name}
    \trespond "#{text}" 200
    }
    """
  end

  def proxy(cfg, _name, fqdn, job_id, upstream) do
    """
    # obs_factor build #{job_id}: #{fqdn} -> #{upstream}. Written by the builder.
    #{cfg.site_prefix}#{fqdn} {
    \tencode gzip zstd
    \treverse_proxy #{upstream}
    }
    """
  end

  @doc "Writes the site block and reloads Caddy; restores the old block on failure."
  def put(cfg, name, content, log) do
    File.mkdir_p!(cfg.caddy_dir)
    path = path(cfg, name)
    previous = if File.exists?(path), do: File.read!(path), else: nil
    File.write!(path, content)
    log.("wrote #{path}")

    case reload(cfg, log) do
      :ok ->
        :ok

      {:error, why} ->
        if previous, do: File.write!(path, previous), else: File.rm(path)
        log.("Caddy refused the new block; put the previous one back")
        _ = reload(cfg, log)
        {:error, why}
    end
  end

  def delete(cfg, name, log) do
    File.rm(path(cfg, name))
    reload(cfg, log)
  end

  defp reload(cfg, log) do
    args = ["exec", cfg.caddy_container, "caddy", "reload", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

    case Shell.run("docker", args, [timeout: 30_000], log) do
      {:ok, _} ->
        log.("caddy reload: ok")
        :ok

      {:error, msg, tail} ->
        {:error, "caddy reload failed (#{msg}): #{tail |> Enum.take(-3) |> Enum.join(" | ")}"}
    end
  end

  @doc """
  GET `path` on `fqdn` through Caddy's listener (Host header), until it
  answers below 500 (and, if `lot?` is given, with or without the lot
  header), or `seconds` pass.
  """
  def wait_answer(cfg, fqdn, path, lot?, seconds, log) do
    url = cfg.caddy_http <> path
    deadline = System.monotonic_time(:second) + seconds
    attempt(url, fqdn, lot?, deadline, log, nil)
  end

  defp attempt(url, fqdn, lot?, deadline, log, last) do
    result =
      Req.get(url,
        headers: [{"host", fqdn}],
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        decode_body: false
      )

    outcome =
      case result do
        {:ok, %Req.Response{status: s} = r} ->
          lot = Req.Response.get_header(r, String.downcase(@lot_header)) != []

          cond do
            s < 500 and lot == lot? -> {:ok, s}
            true -> {:retry, "answered #{s}#{if lot, do: " (still the lot)", else: ""}"}
          end

        {:error, e} ->
          {:retry, Exception.message(e)}
      end

    case outcome do
      {:ok, s} ->
        log.("GET #{url} Host: #{fqdn} -> #{s}")
        {:ok, s}

      {:retry, why} ->
        if why != last, do: log.("GET #{url} Host: #{fqdn}: #{why}")

        if System.monotonic_time(:second) < deadline do
          Process.sleep(2_000)
          attempt(url, fqdn, lot?, deadline, log, why)
        else
          {:error, "#{fqdn}#{URI.parse(url).path} never answered as expected: #{why}"}
        end
    end
  end
end
