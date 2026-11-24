defmodule ObsFactor.WebhookGuard do
  @moduledoc """
  Where the observer may POST: a webhook a logged-in person typed in (an
  alert route, `ObsFactor.Alerts`; a writeup schedule,
  `ObsFactor.Writeup.Schedules`). Without this, anyone with the password can
  make the observer, which sits inside the box's Docker network, POST to
  `http://127.0.0.1:...`, `http://169.254.169.254/...` (a cloud metadata
  service) or a neighbour container on `172.x`, and read the status back
  from the route's last error.

  Refused: loopback, private (RFC 1918, fc00::/7), link-local, carrier-grade
  NAT, "this network", benchmarking, multicast and reserved addresses, the
  IPv4 ones also when mapped into IPv6 or NAT64, and the names `localhost`
  and `*.localhost`. `ALERT_ALLOW_PRIVATE_HOSTS=true` (config
  `:alert_allow_private_hosts`) lifts that, for a webhook receiver that
  really is on the box or the LAN.

  Checked twice:

    * when saved (`check/2`): the scheme, a literal address, and what the
      name resolves to now. A name that does not resolve is accepted (DNS
      may be down, the receiver may not exist yet) and checked again;
    * when sent (`check(url, send: true)`, done by `post/2`): the name is
      resolved again, and one that does not resolve is refused. A name that
      moved to a private address since it was saved is caught here.

  `post/2` does not follow redirects: a public URL that answers 302 to
  `http://169.254.169.254/` would otherwise walk around the check.

  Not covered: a name that resolves to a public address for the check and to
  a private one a moment later for the connection (DNS rebinding with a
  zero TTL). Closing that needs the connection pinned to the checked
  address, which Req/Finch do not offer for https without giving up SNI.
  """

  import Bitwise

  @doc """
  `{:ok, url}` (trimmed) or `{:error, reason}`. Options: `send: true` (an
  unresolvable name is refused), `allow_private:` (default: the config),
  `resolve:` a `fn host -> {:ok, [ip]} | {:error, reason}` (tests).
  """
  def check(url, opts \\ [])

  def check(url, opts) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["https", "http"] and is_binary(h) and h != "" ->
        if allow_private?(opts), do: {:ok, url}, else: host_ok(url, h, opts)

      _ ->
        {:error, "a webhook is an http(s) URL"}
    end
  end

  def check(_, _), do: {:error, "a webhook is an http(s) URL"}

  @doc "Is this address one the observer must not be sent to?"
  def private?({a, b, _, _} = ip) when is_integer(a) and is_integer(b) do
    Enum.any?(
      [
        {{0, 0, 0, 0}, 8},
        {{10, 0, 0, 0}, 8},
        {{100, 64, 0, 0}, 10},
        {{127, 0, 0, 0}, 8},
        {{169, 254, 0, 0}, 16},
        {{172, 16, 0, 0}, 12},
        {{192, 0, 0, 0}, 24},
        {{192, 168, 0, 0}, 16},
        {{198, 18, 0, 0}, 15},
        {{224, 0, 0, 0}, 4},
        {{240, 0, 0, 0}, 4}
      ],
      fn {net, bits} -> in_net4?(ip, net, bits) end
    )
  end

  # ::ffff:a.b.c.d and 64:ff9b::a.b.c.d carry an IPv4 address: judge that
  def private?({0, 0, 0, 0, 0, 0xFFFF, x, y}), do: private?(v4(x, y))
  def private?({0x64, 0xFF9B, 0, 0, 0, 0, x, y}), do: private?(v4(x, y))
  def private?({0, 0, 0, 0, 0, 0, 0, w}) when w in [0, 1], do: true
  def private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  def private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true
  def private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFF00) == 0xFF00, do: true
  def private?({_, _, _, _, _, _, _, _}), do: false

  @doc """
  POST `body` as JSON to a checked `url`, no redirects, 10 s. `:ok` or
  `{:error, reason}`; never raises.
  """
  def post(url, body, opts \\ []) do
    with {:ok, url} <- check(url, Keyword.put(opts, :send, true)) do
      case Req.post(url, json: body, receive_timeout: 10_000, retry: false, redirect: false) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        {:ok, %{status: s}} when s in 300..399 -> {:error, "answered #{s} (a redirect, not followed)"}
        {:ok, %{status: s}} -> {:error, "answered #{s}"}
        {:error, e} -> {:error, Exception.message(e)}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---- the host -------------------------------------------------------------

  defp host_ok(url, host, opts) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    cond do
      host == "localhost" or String.ends_with?(host, ".localhost") ->
        {:error, "#{host} is this machine: refused (ALERT_ALLOW_PRIVATE_HOSTS=true allows it)"}

      ip = literal(host) ->
        if private?(ip), do: refused(host, ip), else: {:ok, url}

      true ->
        resolve = Keyword.get(opts, :resolve, &resolve/1)

        case resolve.(host) do
          {:ok, [_ | _] = ips} ->
            case Enum.find(ips, &private?/1) do
              nil -> {:ok, url}
              ip -> refused(host, ip)
            end

          _ ->
            if opts[:send], do: {:error, "#{host} does not resolve"}, else: {:ok, url}
        end
    end
  end

  defp refused(host, ip) do
    addr = ip |> :inet.ntoa() |> to_string()
    what = if addr == host, do: addr, else: "#{host} (#{addr})"
    {:error, "#{what} is a private, loopback or link-local address: refused (ALERT_ALLOW_PRIVATE_HOSTS=true allows it)"}
  end

  # URI.parse leaves the brackets off an IPv6 host
  defp literal(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  # every address the name has, v4 and v6, within 3 s
  defp resolve(host) do
    task =
      Task.async(fn ->
        h = String.to_charlist(host)
        v4 = case :inet.getaddrs(h, :inet) do {:ok, l} -> l; _ -> [] end
        v6 = case :inet.getaddrs(h, :inet6) do {:ok, l} -> l; _ -> [] end
        v4 ++ v6
      end)

    case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, [_ | _] = ips} -> {:ok, ips}
      {:ok, []} -> {:error, :nxdomain}
      nil -> {:error, :timeout}
    end
  end

  defp allow_private?(opts),
    do: Keyword.get_lazy(opts, :allow_private, fn -> Application.get_env(:obs_factor, :alert_allow_private_hosts, false) == true end)

  defp v4(x, y), do: {x >>> 8, x &&& 0xFF, y >>> 8, y &&& 0xFF}

  defp in_net4?({a, b, c, d}, {na, nb, nc, nd}, bits) do
    ip = (a <<< 24) + (b <<< 16) + (c <<< 8) + d
    net = (na <<< 24) + (nb <<< 16) + (nc <<< 8) + nd
    mask = (0xFFFFFFFF <<< (32 - bits)) &&& 0xFFFFFFFF
    (ip &&& mask) == (net &&& mask)
  end
end
