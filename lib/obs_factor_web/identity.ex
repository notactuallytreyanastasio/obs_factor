defmodule ObsFactorWeb.Identity do
  @moduledoc """
  Who is on the page, and what they may do (docs/contract.md "Identities
  and roles").

  An identity is a map with string keys, kept in the session as
  `:identity` and carried in the socket token's claims:

      %{"login" => "bobbby", "role" => "operator", "via" => "github"}
      %{"login" => nil,      "role" => "operator", "via" => "password"}

  `via` is how they signed in: `"github"` (ObsFactorWeb.GitHubAuthController)
  or `"password"`, the break-glass fallback. Under a password login there is
  no login, so `by` stays the name the page was given.

  Roles: `"operator"` may do everything; `"viewer"` may look, replay and
  write up, and nothing listed in `operator_only/0`. A GitHub login's role is
  worked out again from the configuration on every request and every socket
  connect (`current/1`), so taking someone out of OBS_FACTOR_OPERATORS or
  GITHUB_ALLOWED_LOGINS takes effect at their next request, not at their next
  login.

  Configuration, `config :obs_factor, :identity` (config/runtime.exs):

    * `github_client_id`, `github_client_secret`: both set turns GitHub on
    * `allowed_logins`: GitHub logins that may sign in (GITHUB_ALLOWED_LOGINS)
    * `operators`: logins that are operators (OBS_FACTOR_OPERATORS); they
      may sign in whether or not they are also in `allowed_logins`
    * `password_login`: false turns the password off (default true)
    * `password_role`: the role a password login gets (default "operator":
      it is the break glass)

  Logins compare case-insensitively, as GitHub's do.
  """

  require Logger

  @operator_only ~w(observer_action create_token revoke_token save_schedule delete_schedule run_schedule
                    save_alert_route delete_alert_route test_alert_route save_slo delete_slo
                    retry_job cancel_job delete_job pause_queue resume_queue run_cron)

  @what %{
    "observer_action" => "act on a process (observer action)",
    "create_token" => "make a script token",
    "revoke_token" => "revoke a script token",
    "save_schedule" => "create or change a scheduled writeup",
    "delete_schedule" => "delete a scheduled writeup",
    "run_schedule" => "run a scheduled writeup",
    # chapters 28 and 32, built beside this one: their writes are an operator's too
    "save_alert_route" => "create or change an alert route",
    "delete_alert_route" => "delete an alert route",
    "test_alert_route" => "send a test alert",
    "save_slo" => "set an error budget",
    "delete_slo" => "remove an error budget",
    # the Oban tab (ObsFactorWeb.JobsChannel)
    "retry_job" => "retry a job",
    "cancel_job" => "cancel a job",
    "delete_job" => "delete a job",
    "pause_queue" => "pause a queue",
    "resume_queue" => "resume a queue",
    "run_cron" => "run a cron job now"
  }

  defp role_words(%{"role" => r}) when is_binary(r), do: "a " <> r
  defp role_words(_), do: "not signed in as anyone"

  @doc "The actions only an operator may take."
  def operator_only, do: @operator_only

  defp conf, do: Application.get_env(:obs_factor, :identity, [])

  @doc "Is GitHub sign-in configured (client id and secret)?"
  def github? do
    c = conf()
    present?(c[:github_client_id]) and present?(c[:github_client_secret])
  end

  @doc "Is the password login on? Off when `password_login: false` or no password is set."
  def password? do
    Keyword.get(conf(), :password_login, true) != false and
      present?(Application.get_env(:obs_factor, :password))
  end

  def password_role do
    case conf()[:password_role] do
      "viewer" -> "viewer"
      _ -> "operator"
    end
  end

  def allowed_logins, do: conf() |> Keyword.get(:allowed_logins, []) |> norm()
  def operators, do: conf() |> Keyword.get(:operators, []) |> norm()

  @doc "The identity of a password login."
  def password_identity, do: %{"login" => nil, "role" => password_role(), "via" => "password"}

  @doc """
  A GitHub login, checked against the allow list: `{:ok, identity}` or
  `{:error, reason}`.
  """
  def from_github(login) when is_binary(login) and login != "" do
    l = String.downcase(login)

    cond do
      l in operators() -> {:ok, %{"login" => login, "role" => "operator", "via" => "github"}}
      l in allowed_logins() -> {:ok, %{"login" => login, "role" => "viewer", "via" => "github"}}
      true -> {:error, "#{login} is not allowed on this observer (GITHUB_ALLOWED_LOGINS)"}
    end
  end

  def from_github(other), do: {:error, "GitHub gave no login: #{inspect(other)}"}

  @doc """
  The identity a session or socket holds, as of now: a GitHub one with its
  role worked out again (nil once the login is no longer allowed), a
  password one with the current password role (nil once the password login
  is off). `legacy: true` is a session from before identities (`authed: true`
  and nothing else), which could only have been a password login.
  """
  def current(identity, opts \\ [])

  def current(%{"via" => "github", "login" => login}, _) do
    if github?() do
      case from_github(login) do
        {:ok, id} -> id
        {:error, _} -> nil
      end
    end
  end

  def current(%{"via" => "password"}, _), do: if(password?(), do: password_identity())
  def current(nil, legacy: true), do: if(password?(), do: password_identity())
  def current(_, _), do: nil

  @doc "The session's identity, as of now, or nil when it is not signed in."
  def of_session(conn) do
    if Plug.Conn.get_session(conn, :authed) == true do
      case Plug.Conn.get_session(conn, :identity) do
        nil -> current(nil, legacy: true)
        id -> current(id)
      end
    end
  end

  def operator?(%{"role" => "operator"}), do: true
  def operator?(_), do: false

  @doc """
  May `identity` take `action`? `:ok`, or `{:error, reason}` for a viewer (or
  nobody) asking for an operator's action. Either way the decision is logged
  with the identity (event `identity.allowed` / `identity.refused`).
  """
  def authorize(identity, action, meta \\ []) when is_binary(action) do
    if action not in @operator_only or operator?(identity) do
      log(identity, action, :allowed, meta)
      :ok
    else
      reason =
        "only an operator may #{@what[action]}; #{describe(identity)} is #{role_words(identity)}"

      log(identity, action, :refused, Keyword.put(meta, :reason, reason))
      {:error, reason}
    end
  end

  @doc """
  What to record as "by": the GitHub login, whatever the page said; under a
  password login, the name the page gave (cleaned, at most 60 characters),
  or nil.
  """
  def by(%{"via" => "github", "login" => login}, _given) when is_binary(login), do: login

  def by(_identity, given) when is_binary(given) do
    case given |> String.replace(~r/[^[:print:]]/u, "") |> String.trim() |> String.slice(0, 60) do
      "" -> nil
      clean -> clean
    end
  end

  def by(_, _), do: nil

  @doc "`params` with `\"by\"` set from the identity (see `by/2`)."
  def sign(params, identity) when is_map(params),
    do: Map.put(params, "by", by(identity, params["by"]))

  @doc "Who, in words: `github:bobbby`, `password (dave)`, `nobody`."
  def describe(%{"via" => "github", "login" => l}), do: "github:#{l}"
  def describe(%{"via" => "password"}), do: "password"
  def describe(_), do: "nobody"

  @doc """
  One log line for something an identity did: event `identity.<outcome>`
  (`allowed`, `refused`, `signed_in`, `signed_out`, `denied`), with
  `login`, `role`, `via`, `action` and whatever `meta` adds.
  """
  def log(identity, action, outcome, meta \\ []) do
    id = identity || %{}
    by = meta[:by]
    who = describe(identity) <> if(by && id["via"] != "github", do: " (#{by})", else: "")

    level = if outcome in [:refused, :denied], do: :warning, else: :info

    Logger.log(
      level,
      "#{who} #{outcome} #{action}#{if meta[:reason], do: ": " <> meta[:reason], else: ""}",
      [
        event: "identity.#{outcome}",
        login: id["login"],
        role: id["role"],
        via: id["via"],
        action: action
      ] ++
        Keyword.take(meta, [:by, :reason, :node, :path, :target])
    )

    :ok
  end

  defp norm(list) when is_list(list),
    do: list |> Enum.map(&String.downcase(String.trim(&1))) |> Enum.reject(&(&1 == ""))

  defp norm(_), do: []

  defp present?(s), do: is_binary(s) and String.trim(s) != ""
end
