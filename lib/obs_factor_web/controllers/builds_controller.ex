defmodule ObsFactorWeb.BuildsController do
  @moduledoc """
  The browser's door to the builder, behind the observer's login:
  `POST /api/builds` starts a job, `GET /api/builds/:id` is one job with its
  log. The observer holds no build power itself; it forwards to BUILDER_URL
  with BUILDER_TOKEN, and passes the builder's status and body through.
  """
  use ObsFactorWeb, :controller

  alias ObsFactor.BuilderClient

  def create(conn, params) do
    forward(conn, fn url, token ->
      BuilderClient.post(url, token, "/builder/api/jobs", Map.take(params, ~w(name mode repo ref label)))
    end)
  end

  def show(conn, %{"id" => id}) do
    if Regex.match?(~r/^[a-z0-9-]{1,80}$/, id) do
      forward(conn, fn url, token -> BuilderClient.get(url, token, "/builder/api/jobs/" <> id) end)
    else
      conn |> put_status(400) |> json(%{error: "bad build id"})
    end
  end

  def log(conn, %{"id" => id}) do
    if Regex.match?(~r/^[a-z0-9-]{1,80}$/, id) do
      forward(conn, fn url, token -> BuilderClient.get(url, token, "/builder/api/jobs/" <> id <> "/log") end)
    else
      conn |> put_status(400) |> json(%{error: "bad build id"})
    end
  end

  defp forward(conn, fun) do
    cfg = BuilderClient.config()

    case cfg[:url] do
      nil ->
        conn |> put_status(404) |> json(%{error: "no builder configured (BUILDER_URL)"})

      url ->
        case fun.(url, cfg[:token]) do
          {:ok, status, body} -> conn |> put_status(status) |> json(body)
          {:error, msg} -> conn |> put_status(502) |> json(%{error: "builder: #{msg}"})
        end
    end
  end
end
