defmodule ObsFactorWeb.BuilderController do
  @moduledoc "The builder's own API (OBS_ROLE=builder). The observer is its only client."
  use ObsFactorWeb, :controller

  alias ObsFactor.Builder.Jobs

  def index(conn, _params) do
    json(conn, %{domain: Jobs.config().domain, modes: Jobs.modes(), jobs: Jobs.list()})
  end

  def create(conn, params) do
    case Jobs.create(Map.take(params, ~w(name mode repo ref label))) do
      {:ok, job} -> conn |> put_status(201) |> json(job)
      {:error, msg} -> conn |> put_status(422) |> json(%{error: msg})
    end
  end

  def show(conn, %{"id" => id}) do
    case Jobs.get(id) do
      {:ok, job} -> json(conn, job)
      :error -> conn |> put_status(404) |> json(%{error: "no build #{id}"})
    end
  end

  def log(conn, %{"id" => id}) do
    case Jobs.full_log(id) do
      nil -> conn |> put_status(404) |> json(%{error: "no log for build #{id}"})
      lines -> json(conn, %{id: id, log: lines})
    end
  end
end
