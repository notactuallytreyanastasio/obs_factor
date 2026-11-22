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

  @doc "The observer's own VM, processes, tables and log: `ObsFactor.Beam`."
  def beam(conn, params) do
    level = Map.get(params, "level", "debug")

    if level in Enum.map(ObsFactor.LogRing.levels(), &Atom.to_string/1) do
      json(conn, ObsFactor.Beam.report(log_level: String.to_existing_atom(level)))
    else
      conn |> put_status(400) |> json(%{error: "level must be one of #{Enum.join(ObsFactor.LogRing.levels(), ", ")}"})
    end
  end

  @doc """
  The observer's log ring for the log explorer: every event kept with an id
  above `after` (default 0, i.e. all of them), oldest first. The explorer
  polls with the last id it has to tail.
  """
  def logs(conn, params) do
    case Integer.parse(Map.get(params, "after", "0")) do
      {after_id, ""} when after_id >= 0 ->
        events = ObsFactor.LogRing.since(after_id)
        json(conn, %{events: events, last_id: List.last(events)[:id] || after_id, kept: ObsFactor.LogRing.keep()})

      _ ->
        conn |> put_status(400) |> json(%{error: "after must be a non-negative integer"})
    end
  end
end
