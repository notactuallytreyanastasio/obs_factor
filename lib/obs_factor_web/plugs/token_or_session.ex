defmodule ObsFactorWeb.Plugs.TokenOrSession do
  @moduledoc """
  For what scripts read: an `Authorization: Bearer obsf_...` token with the
  route's scope (`ObsFactor.ApiTokens`), or else the page's session. A
  bearer that is sent and not good is refused with why: it does not fall
  back to the session, so a broken cron job is never quietly someone's
  browser.
  """
  import Plug.Conn

  def init(opts), do: Keyword.fetch!(opts, :scope)

  def call(conn, scope) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        case ObsFactor.ApiTokens.verify(String.trim(token), scope) do
          {:ok, t} -> assign(conn, :api_token, t)
          {:error, why} -> deny(conn, why)
        end

      _ ->
        if get_session(conn, :authed) == true, do: conn, else: deny(conn, "unauthorized: log in, or send Authorization: Bearer <token>")
    end
  end

  defp deny(conn, why) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: why}))
    |> halt()
  end
end
