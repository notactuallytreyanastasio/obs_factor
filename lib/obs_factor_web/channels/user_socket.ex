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
  # error budgets per app (ObsFactor.SLOs), the board's SLO tab
  channel "slo", ObsFactorWeb.SLOChannel
  channel "alerts", ObsFactorWeb.AlertsChannel # alerts that go out (ObsFactor.Alerts)
  # what a flagged BEAM was doing at the moment (ObsFactor.Evidence)
  channel "evidence", ObsFactorWeb.EvidenceChannel
  channel "observer:*", ObsFactorWeb.FeedChannel
  channel "history:*", ObsFactorWeb.FeedChannel
  channel "builds:*", ObsFactorWeb.FeedChannel
  # deploys (ObsFactor.Deploys): the timeline's deploy marks
  channel "deploys", ObsFactorWeb.DeploysChannel

  @salt "obs_factor socket"
  @max_age_s 60

  def max_age_s, do: @max_age_s

  @doc "A token for the session `sid` (`opts` as `Phoenix.Token.sign/4`; tests pass `signed_at`)."
  def token(sid, opts \\ []), do: Phoenix.Token.sign(ObsFactorWeb.Endpoint, @salt, sid, opts)

  @doc "`{:ok, sid}` or `{:error, :invalid | :expired | :missing}`."
  def verify(token) when is_binary(token),
    do: Phoenix.Token.verify(ObsFactorWeb.Endpoint, @salt, token, max_age: @max_age_s)

  def verify(_), do: {:error, :missing}

  @impl true
  def connect(params, socket, _connect_info) do
    case verify(params["token"]) do
      {:ok, sid} ->
        {:ok, assign(socket, :sid, sid)}

      # logged as socket.refused, reason "token invalid" etc. (ObsFactorWeb.Log)
      {:error, reason} ->
        _ = ObsFactorWeb.Log.refuse("token #{reason}", :connect)
        {:error, reason}
    end
  end

  @impl true
  def id(socket), do: "session:" <> socket.assigns.sid
end
