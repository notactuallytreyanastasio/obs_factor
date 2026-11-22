defmodule ObsFactor.BuilderClient do
  @moduledoc "The observer's HTTP client for the builder's API (bearer token, JSON)."

  def config, do: Application.get_env(:obs_factor, :builder_client, [])

  def get(base, token, path), do: request(:get, base, token, path, nil)
  def post(base, token, path, body), do: request(:post, base, token, path, body)

  defp request(method, base, token, path, body) do
    opts = [
      method: method,
      url: base <> path,
      headers: [{"authorization", "Bearer " <> token}],
      finch: [name: ObsFactor.Finch],
      retry: false,
      redirect: false,
      receive_timeout: 4_000
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, %Req.TransportError{reason: :econnrefused}} -> {:error, "connection refused"}
      {:error, %Req.TransportError{reason: :nxdomain}} -> {:error, "host not found"}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, "timed out"}
      {:error, e} -> {:error, ObsFactor.Collector.short(Exception.message(e))}
    end
  end
end
