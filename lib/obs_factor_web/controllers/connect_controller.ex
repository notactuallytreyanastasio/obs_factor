defmodule ObsFactorWeb.ConnectController do
  @moduledoc """
  "Connect an app" (docs/CONNECT.md, ObsFactor.Connect), behind the session.

    GET /api/connect?app=my_app&service=my-app&kind=phoenix[&label&hosts&databases&platform&probe_port&app_dir]

  -> 200 `{"input", "report_url", "snippets": [...], "checklist": [...]}`,
  or 422 `{"error"}` naming the field. The page asks again every few
  seconds while it is open: the checklist is what the observer sees now.
  """
  use ObsFactorWeb, :controller

  alias ObsFactor.Connect

  def show(conn, params) do
    case Connect.input(params) do
      {:ok, input} ->
        json(conn, %{
          input: input,
          report_url: Connect.report_url(input),
          snippets: Connect.generate(input),
          checklist: if(params["check"] == "false", do: [], else: Connect.checklist(input))
        })

      {:error, message} ->
        conn |> put_status(422) |> json(%{error: message})
    end
  end
end
