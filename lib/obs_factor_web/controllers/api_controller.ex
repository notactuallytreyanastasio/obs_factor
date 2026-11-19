defmodule ObsFactorWeb.ApiController do
  use ObsFactorWeb, :controller

  alias ObsFactor.{History, Store}

  def snapshot(conn, _params) do
    case Store.snapshot() do
      {:ok, json} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, json)

      {:error, message} ->
        conn |> put_status(500) |> json(%{error: "snapshot build failed: #{message}"})

      :none ->
        conn |> put_status(503) |> json(%{error: "no snapshot yet"})
    end
  end

  def history(conn, %{"node" => node} = params) do
    res = Map.get(params, "res", "5s")

    cond do
      res not in ["5s", "1m"] ->
        conn |> put_status(400) |> json(%{error: "res must be 5s or 1m"})

      true ->
        case History.query(node, res) do
          {:ok, series} -> json(conn, %{node: node, res: res, series: series})
          :unknown_node -> conn |> put_status(404) |> json(%{error: "unknown node #{node}"})
        end
    end
  end

  def history(conn, _params) do
    conn |> put_status(400) |> json(%{error: "node is required"})
  end
end
