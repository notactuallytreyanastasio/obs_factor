defmodule ObsFactorWeb.AuthController do
  @moduledoc """
  One password, compared in constant time: both sides are hashed to 32 bytes
  first so that `Plug.Crypto.secure_compare/2` never short-circuits on length.
  """

  use ObsFactorWeb, :controller

  # identities: the page shows only the ways in that are on
  # (ObsFactorWeb.Identity): <!--github-->...<!--/github--> and
  # <!--password-->...<!--/password--> are cut out when theirs is off
  def show(conn, _params) do
    ObsFactorWeb.StaticPage.send_page(conn, "login.html", fn html ->
      html
      |> cut("github", ObsFactorWeb.Identity.github?())
      |> cut("password", ObsFactorWeb.Identity.password?())
    end)
  end

  defp cut(html, _what, true), do: html
  defp cut(html, what, false), do: String.replace(html, ~r/<!--#{what}-->.*?<!--\/#{what}-->/s, "")

  def create(conn, params) do
    cond do
      # identities: the break glass can be switched off (OBS_FACTOR_PASSWORD_LOGIN=off)
      not ObsFactorWeb.Identity.password?() ->
        ObsFactorWeb.Identity.log(nil, "sign_in", :denied, reason: "the password login is off")
        redirect(conn, to: "/login?error=off")

      valid_password?(params["password"]) ->
        identity = ObsFactorWeb.Identity.password_identity()
        ObsFactorWeb.Identity.log(identity, "sign_in", :signed_in)

        conn
        |> configure_session(renew: true)
        |> put_session(:authed, true)
        |> put_session(:identity, identity)
        |> put_session(:sid, ObsFactorWeb.SocketTokenController.new_sid())
        |> redirect(to: "/")

      true ->
        ObsFactorWeb.Identity.log(nil, "sign_in", :denied, reason: "wrong password")
        redirect(conn, to: "/login?error=1")
    end
  end

  # the session's open sockets (ObsFactorWeb.UserSocket.id/1) close too
  def delete(conn, _params) do
    if id = get_session(conn, :identity), do: ObsFactorWeb.Identity.log(id, "sign_out", :signed_out)
    if sid = get_session(conn, :sid), do: ObsFactorWeb.Endpoint.broadcast("session:" <> sid, "disconnect", %{})

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
