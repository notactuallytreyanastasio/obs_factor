defmodule ObsFactorWeb.Plugs.RequireSession do
  @moduledoc """
  The session gate. Without `authed: true` in the session, pages redirect to
  `/login` and the API answers 401 JSON.
  """

  import Plug.Conn

  def init(opts), do: Keyword.fetch!(opts, :on_missing)

  def call(conn, on_missing) do
    if get_session(conn, :authed) == true do
      conn
    else
      deny(conn, on_missing)
    end
  end

  defp deny(conn, :redirect) do
    conn
    |> put_resp_header("location", "/login")
    |> send_resp(302, "")
    |> halt()
  end

  defp deny(conn, :json) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
