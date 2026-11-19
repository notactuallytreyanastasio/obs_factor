defmodule ObsFactor.Probes do
  @moduledoc """
  HTTP GET of every topology node's `probe` URL, concurrently, 2 s timeout,
  redirects not followed. A probe is ok when the app answered with a status
  below 500: a 302 to a login page or a 404 on `/` still means the process is
  up and serving. Connection errors, timeouts and 5xx are failures.

  The source itself is ok when the probes ran; a failing probe is that node's
  problem, reported on the node.
  """

  @behaviour ObsFactor.Collector

  @timeout 2_000

  @impl true
  def name, do: :probes

  @impl true
  def init_state(opts), do: %{targets: Keyword.fetch!(opts, :targets)}

  @impl true
  def collect(%{targets: targets} = state) do
    results =
      targets
      |> Task.async_stream(fn {id, url} -> {id, probe(url)} end,
        max_concurrency: 32,
        timeout: @timeout + 1_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(targets)
      |> Map.new(fn
        {{:ok, result}, _} -> result
        {{:exit, _}, {id, _}} -> {id, %{ok: false, code: nil, ms: nil, error: "timed out"}}
      end)

    {:ok, results, state}
  end

  def probe(url) do
    case ObsFactor.Http.get(url, timeout: @timeout, decode: false) do
      {:ok, code, _body, ms} when code < 500 -> %{ok: true, code: code, ms: ms, error: nil}
      {:ok, code, _body, ms} -> %{ok: false, code: code, ms: ms, error: "answered #{code}"}
      {:error, message} -> %{ok: false, code: nil, ms: nil, error: message}
    end
  end
end
