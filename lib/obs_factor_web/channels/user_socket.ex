defmodule ObsFactorWeb.UserSocket do
  @moduledoc """
  The page's one websocket, at `/socket/websocket`. Every live thing the
  page shows arrives on a channel of it (docs/contract.md "Live: one
  socket").

  Connecting needs `token`, a `Phoenix.Token` from `GET /api/socket_token`
  (behind the login), valid for 60 s: enough to open the socket, not a
  standing credential. It carries the session's id, so logging out
  disconnects that session's sockets (`ObsFactorWeb.AuthController`). A
  missing, invalid or expired token is refused (HTTP 403 on the upgrade).
  """
  use Phoenix.Socket

  channel "snapshots", ObsFactorWeb.SnapshotsChannel
  channel "objectives", ObsFactorWeb.ObjectivesChannel
  channel "logs", ObsFactorWeb.LogsChannel
  channel "actions", ObsFactorWeb.ActionsChannel
  channel "tape", ObsFactorWeb.TapeChannel
  channel "observer:*", ObsFactorWeb.FeedChannel
  channel "history:*", ObsFactorWeb.FeedChannel
  channel "builds:*", ObsFactorWeb.FeedChannel

  @salt "obs_factor socket"
  @max_age_s 60

  def max_age_s, do: @max_age_s

  @doc """
  A token for the session `sid` (`opts` as `Phoenix.Token.sign/4`; tests pass
  `signed_at`). With `identity:` (identities: `ObsFactorWeb.Identity`) the
  claims are `%{"sid", "identity"}`; without, the bare sid, which connects
  a socket with no identity: it can watch, and no operator action.
  """
  def token(sid, opts \\ []) do
    {identity, opts} = Keyword.pop(opts, :identity)
    claims = if identity, do: %{"sid" => sid, "identity" => identity}, else: sid
    Phoenix.Token.sign(ObsFactorWeb.Endpoint, @salt, claims, opts)
  end

  @doc "`{:ok, sid}` or `{:error, :invalid | :expired | :missing}`."
  def verify(token) do
    with {:ok, %{sid: sid}} <- claims(token), do: {:ok, sid}
  end

  @doc "`{:ok, %{sid, identity}}` (identity nil for a bare-sid token) or `{:error, ...}` as `verify/1`."
  def claims(token) when is_binary(token) do
    case Phoenix.Token.verify(ObsFactorWeb.Endpoint, @salt, token, max_age: @max_age_s) do
      {:ok, %{"sid" => sid, "identity" => id}} -> {:ok, %{sid: sid, identity: id}}
      {:ok, sid} when is_binary(sid) -> {:ok, %{sid: sid, identity: nil}}
      {:ok, _} -> {:error, :invalid}
      e -> e
    end
  end

  def claims(_), do: {:error, :missing}

  @impl true
  def connect(params, socket, _connect_info) do
    case claims(params["token"]) do
      # identities: the identity as of now (its role worked out again)
      {:ok, %{sid: sid, identity: identity}} ->
        {:ok, socket |> assign(:sid, sid) |> assign(:identity, identity && ObsFactorWeb.Identity.current(identity))}

      # logged as socket.refused, reason "token invalid" etc. (ObsFactorWeb.Log)
      {:error, reason} ->
        _ = ObsFactorWeb.Log.refuse("token #{reason}", :connect)
        {:error, reason}
    end
  end

  @impl true
  def id(socket), do: "session:" <> socket.assigns.sid
end
