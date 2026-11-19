defmodule ObsFactor.Http do
  @moduledoc """
  The one HTTP client: Req over our own Finch pool (sized so that the ~19
  concurrent Docker stats calls never queue behind each other), no retries, no
  redirects followed, short timeouts. Errors come back as short strings.
  """

  @finch ObsFactor.Finch

  def child_spec(_) do
    Finch.child_spec(
      name: @finch,
      pools: %{
        default: [
          size: 40,
          count: 1,
          conn_max_idle_time: 30_000,
          conn_opts: [transport_opts: [timeout: 2_000]]
        ]
      }
    )
  end

  @doc """
  GET `url`. Options: `:timeout` (receive and pool checkout, ms, default 2000; connect is
  bounded at 2000 by the pool), `:decode` (default true:
  JSON bodies are decoded; false returns the raw binary).
  Returns `{:ok, status, body, ms}` or `{:error, message}`.
  """
  def get(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    started = System.monotonic_time(:millisecond)

    result =
      Req.get(url,
        finch: [name: @finch, pool_timeout: timeout],
        retry: false,
        redirect: false,
        decode_body: Keyword.get(opts, :decode, true),
        receive_timeout: timeout
      )

    ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body, ms}
      {:error, %Req.TransportError{reason: reason}} -> {:error, transport_message(reason)}
      {:error, exception} -> {:error, ObsFactor.Collector.short(Exception.message(exception))}
    end
  end

  defp transport_message(:econnrefused), do: "connection refused"
  defp transport_message(:timeout), do: "timed out"
  defp transport_message(:nxdomain), do: "host not found"
  defp transport_message(:closed), do: "connection closed"
  defp transport_message(:ehostunreach), do: "host unreachable"
  defp transport_message(other), do: inspect(other)
end
