defmodule ObsFactorWeb.AuthController do
  @moduledoc """
  One password, compared in constant time: both sides are hashed to 32 bytes
  first so that `Plug.Crypto.secure_compare/2` never short-circuits on length.
  """

  use ObsFactorWeb, :controller

  def show(conn, _params), do: ObsFactorWeb.StaticPage.send_page(conn, "login.html")

  def create(conn, params) do
    if valid_password?(params["password"]) do
      conn
      |> configure_session(renew: true)
      |> put_session(:authed, true)
      |> redirect(to: "/")
    else
      redirect(conn, to: "/login?error=1")
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  @doc false
  def valid_password?(given) when is_binary(given) do
    case Application.get_env(:obs_factor, :password) do
      expected when is_binary(expected) and expected != "" ->
        Plug.Crypto.secure_compare(digest(given), digest(expected))

      _ ->
        false
    end
  end

  def valid_password?(_), do: false

  defp digest(s), do: :crypto.hash(:sha256, s)
end
