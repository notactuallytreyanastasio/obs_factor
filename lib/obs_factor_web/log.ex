defmodule ObsFactorWeb.Log do
  @moduledoc """
  One structured log event per HTTP request, socket connect and channel
  join, from Phoenix's telemetry (docs/contract.md, "Logs"). This replaces
  `Phoenix.Logger` (`config :phoenix, :logger, false`), whose lines for
  the same things are text only ("Sent 200 in 3ms", "JOINED feed in 30µs").

  | event | level | fields |
  |---|---|---|
  | `http.request` | info | method, path, route, handler, status, took_ms |
  | `http.error_rendered` | the endpoint's (debug) | method, path, status, kind, reason |
  | `socket.connected` | info | transport, took_ms |
  | `socket.refused` | warning | transport, reason, took_ms |
  | `channel.joined` | info | topic, channel, took_ms |
  | `channel.refused` | warning | topic, channel, reason, took_ms |

  `request_id` is already in the request process's Logger metadata
  (`Plug.RequestId`). The endpoint's `log:` option still decides whether a
  request is logged (`ObsFactorWeb.Endpoint.log_level/1`). A refusal's
  `reason` is what the refusing callback put in Logger metadata with
  `refuse/1`: the telemetry event runs in the same process right after it,
  and carries only `:ok | :error`.
  """

  require Logger

  @handler "obs_factor-structured-log"

  @events [
    [:phoenix, :endpoint, :stop],
    [:phoenix, :error_rendered],
    [:phoenix, :socket_connected],
    [:phoenix, :channel_joined]
  ]

  @doc "Attaches the telemetry handlers (idempotent)."
  def attach do
    _ = :telemetry.detach(@handler)
    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  For a socket `connect/3` or channel `join/3` that refuses: records why,
  for the `socket.refused` / `channel.refused` event, and returns
  `{:error, %{reason: reason}}` (a join's refusal) or `{:error, reason}`
  with `as: :connect`.
  """
  def refuse(reason, as \\ :join) do
    Logger.metadata(reason: reason)
    if as == :connect, do: {:error, reason}, else: {:error, %{reason: reason}}
  end

  @doc false
  def handle_event([:phoenix, :endpoint, :stop], %{duration: d}, %{conn: conn} = meta, _) do
    case level(meta[:options][:log], conn) do
      false ->
        :ok

      level ->
        took = took_ms(d)

        Logger.log(level, "#{conn.method} #{conn.request_path} #{conn.status} in #{took} ms",
          event: "http.request",
          method: conn.method,
          path: conn.request_path,
          route: route(conn),
          handler: handler(conn),
          status: conn.status,
          took_ms: took
        )
    end
  end

  def handle_event([:phoenix, :error_rendered], _, %{log: false}, _), do: :ok

  def handle_event([:phoenix, :error_rendered], _, %{log: level, status: status, kind: kind, reason: reason} = meta, _) do
    banner = if kind == :error and is_exception(reason), do: inspect(reason.__struct__), else: inspect(reason, limit: 10)

    Logger.log(level, "converted #{kind} #{banner} to a #{status} response",
      event: "http.error_rendered",
      method: meta.conn.method,
      path: meta.conn.request_path,
      status: status,
      kind: kind,
      reason: banner
    )
  end

  def handle_event([:phoenix, :socket_connected], _, %{log: false}, _), do: :ok

  def handle_event([:phoenix, :socket_connected], %{duration: d}, meta, _) do
    took = took_ms(d)
    # :websocket -> "websocket", a module (a test transport) -> its name
    transport = meta.transport |> inspect() |> String.trim_leading(":")

    case meta.result do
      :ok ->
        Logger.info("socket connected (#{transport}) in #{took} ms",
          event: "socket.connected",
          transport: transport,
          took_ms: took
        )

      :error ->
        reason = take_reason()

        Logger.warning("socket refused (#{transport}): #{reason || "no reason given"}",
          event: "socket.refused",
          transport: transport,
          reason: reason,
          took_ms: took
        )
    end
  end

  # "phoenix" is the heartbeat topic, as Phoenix.Logger skips it.
  def handle_event([:phoenix, :channel_joined], _, %{socket: %{topic: "phoenix" <> _}}, _), do: :ok

  def handle_event([:phoenix, :channel_joined], %{duration: d}, %{socket: socket, result: result}, _) do
    took = took_ms(d)
    channel = inspect(socket.channel)

    case result do
      :ok ->
        Logger.info("joined #{socket.topic} in #{took} ms",
          event: "channel.joined",
          topic: socket.topic,
          channel: channel,
          took_ms: took
        )

      :error ->
        reason = take_reason()

        Logger.warning("refused join #{socket.topic}: #{reason || "no reason given"}",
          event: "channel.refused",
          topic: socket.topic,
          channel: channel,
          reason: reason,
          took_ms: took
        )
    end
  end

  @doc "A telemetry duration (native units) in milliseconds, to the microsecond."
  def took_ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  # The reason refuse/1 left, removed again: a socket connect runs in the
  # HTTP connection's process, which may go on to serve further requests.
  defp take_reason do
    reason = Logger.metadata()[:reason]
    Logger.metadata(reason: nil)
    reason
  end

  defp level(nil, _conn), do: :info
  defp level(level, _conn) when is_atom(level), do: level
  defp level({m, f, a}, conn), do: apply(m, f, [conn | a])

  # The router's pattern ("/api/nodes/:id/observer/*path"), so requests
  # aggregate by route; nil for what the router never saw (static files).
  defp route(%{private: %{phoenix_router: router}} = conn) do
    case Phoenix.Router.route_info(router, conn.method, conn.request_path, conn.host) do
      %{route: route} -> route
      _ -> nil
    end
  end

  defp route(_), do: nil

  defp handler(%{private: %{phoenix_controller: c, phoenix_action: a}}), do: "#{inspect(c)}.#{a}"
  defp handler(_), do: nil
end
