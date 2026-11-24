defmodule ObsFactorWeb.Plugs.RequireSession do
  @moduledoc """
  The session gate. Without `authed: true` in the session, pages redirect to
  `/login` and the API answers 401 JSON. So does a session whose identity
  is no longer allowed (`ObsFactorWeb.Identity`).
  """

  import Plug.Conn

  def init(opts), do: Keyword.fetch!(opts, :on_missing)

  # identities: signed in means an identity that is still good now
  # (ObsFactorWeb.Identity.of_session/1: a login taken off the allow list, or
  # a password session once the password login is off, is signed out), and
  # it is put in `conn.assigns.identity` for the controllers
  def call(conn, on_missing) do
    case ObsFactorWeb.Identity.of_session(conn) do
      nil -> deny(conn, on_missing)
      identity -> assign(conn, :identity, identity)
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
