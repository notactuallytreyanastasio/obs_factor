defmodule ObsFactorWeb.ObjectivesController do
  @moduledoc """
  Mission objectives (ObsFactor.Objectives) over HTTP.

    GET  /api/objectives        undone ones and those done in the last 24 h
    POST /api/objectives        a pin: {node, title, note, by}
    POST /api/objectives/:id    {action: look | done | reopen, note, by}

  `by` is the GitHub login under a GitHub sign-in (ObsFactorWeb.Identity),
  whatever was sent; under the password login it is whatever name the
  person on the floor gave, a label and not an identity.
  503 when this observer has no objectives store (OBJECTIVES_PG_URL unset)
  or it cannot reach Postgres, with the reason.
  """
  use ObsFactorWeb, :controller

  alias ObsFactor.Objectives

  def index(conn, _params) do
    with_store(conn, fn -> Objectives.list() end, fn list -> json(conn, %{objectives: list}) end)
  end

  def create(conn, params) do
    # identities: `by` is the GitHub login when there is one
    params = ObsFactorWeb.Identity.sign(params, conn.assigns[:identity])
    with_store(conn, fn -> Objectives.pin(params) end, fn o -> conn |> put_status(201) |> json(o) end)
  end

  def update(conn, %{"id" => id} = params) do
    params = ObsFactorWeb.Identity.sign(params, conn.assigns[:identity])

    case {Integer.parse(id), params["action"]} do
      {{n, ""}, action} when action in ~w(look done reopen) ->
        with_store(conn, fn -> Objectives.act(n, action, params) end, &json(conn, &1))

      {{_, ""}, other} ->
        conn |> put_status(400) |> json(%{error: "action must be look, done or reopen, not #{inspect(other)}"})

      _ ->
        conn |> put_status(400) |> json(%{error: "not an objective id: #{inspect(id)}"})
    end
  end

  defp with_store(conn, call, ok) do
    if Objectives.enabled?() do
      case call.() do
        {:ok, value} -> ok.(value)
        {:error, "no such objective"} -> conn |> put_status(404) |> json(%{error: "no such objective"})
        {:error, "cannot " <> _ = e} -> conn |> put_status(409) |> json(%{error: e})
        {:error, "this came back" <> _ = e} -> conn |> put_status(409) |> json(%{error: e})
        {:error, e} -> conn |> put_status(503) |> json(%{error: e})
      end
    else
      conn |> put_status(503) |> json(%{error: "no objectives store: OBJECTIVES_PG_URL is not set"})
    end
  end
end
