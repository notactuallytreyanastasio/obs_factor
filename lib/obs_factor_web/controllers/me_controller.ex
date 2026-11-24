defmodule ObsFactorWeb.MeController do
  @moduledoc """
  `GET /api/me`, behind the login: who this session is.

      {"login": "bobbby", "role": "operator", "via": "github", "operator": true,
       "operator_only": ["observer_action", "create_token", ...]}

  `login` is null under the password login: the page then signs with the
  name it was given (identity.js).
  """
  use ObsFactorWeb, :controller

  alias ObsFactorWeb.Identity

  def show(conn, _params) do
    id = conn.assigns[:identity] || %{}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      login: id["login"],
      role: id["role"],
      via: id["via"],
      operator: Identity.operator?(id),
      operator_only: Identity.operator_only()
    })
  end
end
