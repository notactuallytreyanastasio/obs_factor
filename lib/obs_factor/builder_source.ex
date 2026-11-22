defmodule ObsFactor.BuilderSource do
  @moduledoc """
  The builder's jobs, read like any other source: `GET {BUILDER_URL}/builder/api/jobs`
  with the shared token. The observer never asks the builder to do anything
  on a tick; it only reads. Starting a build is a separate, user-initiated
  request (`POST /api/builds`, proxied).
  """

  @behaviour ObsFactor.Collector

  @impl true
  def name, do: :builder

  @impl true
  def init_state(opts), do: %{url: Keyword.fetch!(opts, :url), token: Keyword.fetch!(opts, :token)}

  @impl true
  def collect(%{url: url, token: token} = state) do
    case ObsFactor.BuilderClient.get(url, token, "/builder/api/jobs") do
      {:ok, 200, %{"domain" => domain, "jobs" => jobs} = body} when is_list(jobs) ->
        {:ok, %{domain: domain, modes: body["modes"] || [], jobs: jobs}, state}

      {:ok, status, body} ->
        {:error, "builder answered #{status}: #{inspect(body, limit: 3)}", state}

      {:error, message} ->
        {:error, message, state}
    end
  end
end
