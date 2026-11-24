defmodule ObsFactor.GitHubOAuth do
  @moduledoc """
  GitHub's OAuth web flow, with Req and nothing else
  (https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps):

    1. the browser is sent to `authorize_url/2` with a random `state`
    2. GitHub sends it back to the callback with `code` and that `state`
    3. `exchange/2` trades the code for an access token
       (`POST https://github.com/login/oauth/access_token`)
    4. `user/1` reads who that is (`GET https://api.github.com/user`)

  No scope is asked for: the public profile, which has the login, needs
  none. The token is used for that one read and then dropped; it is not
  kept in the session.

  GitHub's documentation says a bad or expired code is answered with **200**
  and `{"error": "bad_verification_code", "error_description": ...}`, not a
  4xx, so the body is what is checked; the fake GitHub in the tests answers
  that way. An unknown client id is a 404 `{"error":"Not Found"}` (checked
  against github.com, 2026-11-23), reported with its status.

  `config :obs_factor, :identity, github_req_options: [...]` is merged into
  every request; the tests pass `plug: {Req.Test, ObsFactor.GitHubOAuth}`.
  """

  @github "https://github.com"
  @api "https://api.github.com"

  defp conf, do: Application.get_env(:obs_factor, :identity, [])

  @doc "Where to send the browser."
  def authorize_url(state, redirect_uri) do
    @github <>
      "/login/oauth/authorize?" <>
      URI.encode_query(%{
        client_id: conf()[:github_client_id],
        redirect_uri: redirect_uri,
        state: state,
        scope: "",
        allow_signup: "false"
      })
  end

  @doc "The code from the callback, traded for an access token: `{:ok, token}` or `{:error, reason}`."
  def exchange(code, redirect_uri) do
    req(
      method: :post,
      url: @github <> "/login/oauth/access_token",
      headers: [accept: "application/json"],
      form: [
        client_id: conf()[:github_client_id],
        client_secret: conf()[:github_client_secret],
        code: code,
        redirect_uri: redirect_uri
      ]
    )
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => t}}} when is_binary(t) and t != "" ->
        {:ok, t}

      {:ok, %{status: 200, body: %{"error" => e} = b}} ->
        {:error, "GitHub refused the code: #{e}#{desc(b)}"}

      {:ok, %{status: s, body: b}} ->
        {:error,
         "GitHub answered the token exchange with #{s}: #{inspect(b, limit: 5, printable_limit: 200)}"}

      {:error, e} ->
        {:error, "could not reach GitHub: #{Exception.message(e)}"}
    end
  end

  @doc "Who the token belongs to: `{:ok, %{login, id, name}}` or `{:error, reason}`."
  def user(token) do
    req(
      method: :get,
      url: @api <> "/user",
      headers: [
        accept: "application/vnd.github+json",
        authorization: "Bearer " <> token,
        "x-github-api-version": "2022-11-28"
      ]
    )
    |> case do
      {:ok, %{status: 200, body: %{"login" => l} = b}} when is_binary(l) ->
        {:ok, %{login: l, id: b["id"], name: b["name"]}}

      {:ok, %{status: s, body: b}} ->
        {:error,
         "GitHub answered GET /user with #{s}: #{inspect(b, limit: 5, printable_limit: 200)}"}

      {:error, e} ->
        {:error, "could not reach GitHub: #{Exception.message(e)}"}
    end
  end

  defp req(opts) do
    [retry: false, receive_timeout: 10_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(conf()[:github_req_options] || [])
    |> Req.request()
  end

  defp desc(%{"error_description" => d}) when is_binary(d), do: " (#{d})"
  defp desc(_), do: ""
end
