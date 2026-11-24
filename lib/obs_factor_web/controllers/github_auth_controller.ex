defmodule ObsFactorWeb.GitHubAuthController do
  @moduledoc """
  Sign in with GitHub (`ObsFactor.GitHubOAuth`):

    * `GET /auth/github`: a random `state` goes in the session, the browser
      goes to GitHub
    * `GET /auth/github/callback?code&state`: the state must be the
      session's (else a forged callback could sign someone in as somebody
      else); the code is traded for the login; an allowed login gets a new
      session with its identity (`ObsFactorWeb.Identity`)

  Anything that goes wrong sends the browser back to
  `/login?error=github&why=<reason>`, and is logged.

  The callback URL is GITHUB_CALLBACK_URL when set, else the endpoint's
  own URL + `/auth/github/callback`; it must be the one registered on the
  GitHub OAuth app, character for character.
  """
  use ObsFactorWeb, :controller

  alias ObsFactor.GitHubOAuth
  alias ObsFactorWeb.Identity

  def callback_url do
    Application.get_env(:obs_factor, :identity, [])[:github_callback_url] ||
      ObsFactorWeb.Endpoint.url() <> "/auth/github/callback"
  end

  def request(conn, _params) do
    if Identity.github?() do
      state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      conn
      |> put_session(:oauth_state, state)
      |> redirect(external: GitHubOAuth.authorize_url(state, callback_url()))
    else
      fail(
        conn,
        "GitHub sign-in is not configured on this observer (GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET)"
      )
    end
  end

  def callback(conn, params) do
    expected = get_session(conn, :oauth_state)
    conn = delete_session(conn, :oauth_state)

    with true <-
           Identity.github?() || {:error, "GitHub sign-in is not configured on this observer"},
         {:ok, code} <- given(params, "code"),
         :ok <- same_state(expected, params["state"]),
         {:ok, token} <- GitHubOAuth.exchange(code, callback_url()),
         {:ok, user} <- GitHubOAuth.user(token),
         {:ok, identity} <- allowed(user.login) do
      Identity.log(identity, "sign_in", :signed_in)

      conn
      |> configure_session(renew: true)
      |> put_session(:authed, true)
      |> put_session(:identity, identity)
      |> put_session(:sid, ObsFactorWeb.SocketTokenController.new_sid())
      |> redirect(to: "/")
    else
      {:error, {login, why}} -> fail(conn, why, %{"login" => login, "via" => "github"})
      {:error, why} -> fail(conn, why)
    end
  end

  defp given(params, key) do
    case params[key] do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error,
         if(params["error"],
           do: "GitHub said #{params["error"]}: #{params["error_description"]}",
           else: "the callback has no #{key}"
         )}
    end
  end

  defp same_state(expected, given) when is_binary(expected) and is_binary(given) do
    if Plug.Crypto.secure_compare(expected, given),
      do: :ok,
      else: {:error, "the sign-in state does not match this browser's: start again"}
  end

  defp same_state(_, _),
    do: {:error, "no sign-in was started from this browser (no state): start again"}

  defp allowed(login) do
    case Identity.from_github(login) do
      {:ok, id} ->
        {:ok, id}

      {:error, why} ->
        {:error, {login, why}}
    end
  end

  defp fail(conn, why, who \\ nil) do
    Identity.log(who, "sign_in", :denied, reason: why)
    redirect(conn, to: "/login?" <> URI.encode_query(error: "github", why: why))
  end
end
