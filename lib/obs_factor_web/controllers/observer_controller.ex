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

    # identities: a GitHub login signs as itself; only an operator acts
    identity = conn.assigns[:identity]
    by = ObserverProxy.clean_by(ObsFactorWeb.Identity.by(identity, by))

    case ObsFactorWeb.Identity.authorize(identity, "observer_action", by: by, node: id, path: Enum.join(path(params), "/")) do
      :ok ->
        answer(conn, ObserverProxy.call("POST", id, path(params), Map.delete(body, "by"), member: member(conn), by: by))

      {:error, why} ->
        refused = {403, %{"error" => why}}
        ObserverProxy.record_action(id, path(params), body, [member: member(conn), by: by], refused)
        answer(conn, refused)
    end
  end

  defp path(params), do: Map.get(params, "path", [])
  defp member(conn), do: conn.query_params["member"]

  defp answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)
end
