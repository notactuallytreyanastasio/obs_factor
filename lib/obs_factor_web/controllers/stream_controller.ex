defmodule ObsFactorWeb.StreamController do
  @moduledoc """
  Server-sent events: the latest snapshot immediately on connect, then one
  `snapshot` event per tick. The snapshot is encoded once by the ticker and
  the same binary is written to every subscriber.
  """

  use ObsFactorWeb, :controller

  def stream(conn, _params) do
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, ObsFactor.Ticker.topic())

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case ObsFactor.Store.snapshot() do
      {:ok, json} ->
        case send_event(conn, json) do
          {:ok, conn} -> loop(conn)
          {:error, _} -> conn
        end

      _ ->
        loop(conn)
    end
  end

  defp loop(conn) do
    receive do
      {:snapshot, json} ->
        case send_event(conn, json) do
          {:ok, conn} -> loop(conn)
          {:error, _closed} -> conn
        end
    end
  end

  defp send_event(conn, json), do: chunk(conn, ["event: snapshot\ndata: ", json, "\n\n"])
end
