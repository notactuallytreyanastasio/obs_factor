defmodule ObsFactorWeb.HealthController do
  @moduledoc """
  `GET /health`, public: 200 when the observer is observing, 503 when it is
  not (`ObsFactor.Health`), with a small JSON body either way. The status is
  what a checker reads; the body says why, without naming anything inside.

      {"ok":true,"snapshot_age_s":3,"sources_ok":8,"sources_total":9}
      {"ok":false,"reason":"snapshot_stale","snapshot_age_s":94,"sources_ok":2,"sources_total":9}

  The builder (OBS_ROLE=builder) has no ticker; there `/health` is up = ok.
  """
  use ObsFactorWeb, :controller

  def show(conn, _params) do
    if Application.get_env(:obs_factor, :role, :observer) == :builder do
      json(conn, %{ok: true})
    else
      h = ObsFactor.Health.check()
      body = if h.ok, do: Map.delete(h, :reason), else: h

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(if h.ok, do: 200, else: 503)
      |> json(body)
    end
  end
end
