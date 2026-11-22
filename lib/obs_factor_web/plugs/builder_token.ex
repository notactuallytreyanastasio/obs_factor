defmodule ObsFactorWeb.Plugs.BuilderToken do
  @moduledoc """
  Guards the builder's API (`/builder/api/*`): 404 unless this node runs as
  OBS_ROLE=builder, 401 unless `Authorization: Bearer <BUILDER_TOKEN>`.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:obs_factor, :role) != :builder do
      conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not a builder"})) |> halt()
    else
      token = ObsFactor.Builder.Jobs.config().token

      case get_req_header(conn, "authorization") do
        ["Bearer " <> given] ->
          if Plug.Crypto.secure_compare(given, token), do: conn, else: deny(conn)

        _ ->
          deny(conn)
      end
    end
  end

  defp deny(conn),
    do: conn |> put_resp_content_type("application/json") |> send_resp(401, ~s({"error":"bad token"})) |> halt()
end
