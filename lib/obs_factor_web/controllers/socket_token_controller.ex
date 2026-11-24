defmodule ObsFactorWeb.SocketTokenController do
  @moduledoc """
  `GET /api/socket_token[?origin=<location.origin>]`, behind the login:

      {"token": "...", "max_age_s": 60, "origin": {"ok": true}}

  `token` opens `ObsFactorWeb.UserSocket` within `max_age_s`. The page asks
  for one before each (re)connect, which is also how it learns that the
  session is gone (401).

  A browser cannot read why a websocket upgrade was refused, so the origin
  check the socket will make is made here too, on the `origin` the page
  says it has: `"origin": {"ok": false, "reason": ...}` names what is
  allowed. Without `origin` the field is null.
  """
  use ObsFactorWeb, :controller

  alias ObsFactorWeb.UserSocket

  def new_sid, do: Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false)

  def show(conn, params) do
    # sessions from before the socket existed have no sid yet
    {conn, sid} =
      case get_session(conn, :sid) do
        nil ->
          sid = new_sid()
          {put_session(conn, :sid, sid), sid}

        sid ->
          {conn, sid}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      # identities: the token's claims carry who this is (ObsFactorWeb.Identity)
      token: UserSocket.token(sid, identity: conn.assigns[:identity]),
      max_age_s: UserSocket.max_age_s(),
      origin: origin(conn, params["origin"])
    })
  end

  defp origin(_conn, nil), do: nil

  defp origin(conn, origin) when is_binary(origin) do
    probe = %{
      conn
      | req_headers: [{"origin", origin} | List.keydelete(conn.req_headers, "origin", 0)]
    }

    case Phoenix.Socket.Transport.check_origin(probe, UserSocket, ObsFactorWeb.Endpoint, [], & &1) do
      %Plug.Conn{halted: true} ->
        allowed = ObsFactorWeb.Endpoint.config(:check_origin)
        host = ObsFactorWeb.Endpoint.config(:url)[:host]

        %{
          ok: false,
          reason:
            "the observer does not accept a websocket from #{origin}: " <>
              if(allowed in [nil, true],
                do: "only from host #{host} (PHX_HOST); set CHECK_ORIGIN to allow others",
                else: "CHECK_ORIGIN allows #{inspect(allowed)}"
              )
        }

      _ ->
        %{ok: true}
    end
  end

  defp origin(_conn, _), do: %{ok: false, reason: "origin must be a string"}
end
