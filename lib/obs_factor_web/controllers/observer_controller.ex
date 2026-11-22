defmodule ObsFactorWeb.ObserverController do
  @moduledoc """
  `GET|POST /api/nodes/:id/observer/*path`: a building's BEAM, through
  `ObsFactor.ObserverProxy` (docs/contract.md, "Observer"). Behind the
  session like the rest of /api.
  """

  use ObsFactorWeb, :controller

  alias ObsFactor.ObserverProxy

  def read(conn, %{"id" => id} = params) do
    query = Map.delete(conn.query_params, "member")
    answer(conn, ObserverProxy.call("GET", id, path(params), query, member: member(conn)))
  end

  def act(conn, %{"id" => id} = params) do
    body = if is_map(conn.body_params), do: conn.body_params, else: %{}

    by =
      case get_req_header(conn, "x-factory-by") do
        [by | _] when by != "" -> by
        _ -> if is_binary(body["by"]), do: body["by"]
      end

    by = if is_binary(by), do: by |> String.replace(~r/[^[:print:]]/u, "") |> String.slice(0, 80)
    answer(conn, ObserverProxy.call("POST", id, path(params), Map.delete(body, "by"), member: member(conn), by: by))
  end

  defp path(params), do: Map.get(params, "path", [])
  defp member(conn), do: conn.query_params["member"]

  defp answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)
end
