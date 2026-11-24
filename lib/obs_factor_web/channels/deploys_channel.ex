defmodule ObsFactorWeb.DeploysChannel do
  @moduledoc """
  `deploys`: what code went out, for the timeline's deploy marks
  (deploys.js; `ObsFactor.Deploys`).

  The join reply is `%{deploys: [deploy]}`, the last 31 days oldest first,
  or `%{deploys: [], error: reason}` when there is no history (no
  objectives database) or Postgres does not answer; the join succeeds
  either way. A deploy is `%{id, node, sha, dirty, at, subject, repo, url}`
  (`at`: the time in the `.deployed` file, unix ms; `url`: the commit on
  GitHub, nil without a repo).

  Then a `deploy` push with one deploy each time a new one is kept.

  `list` `%{from, to}` (unix ms, at most 31 days) answers `%{deploys}`.
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.{Deploys, Tape}

  @max_window_ms 31 * 86_400_000

  @impl true
  def join("deploys", _params, socket) do
    # the channel's topic is Deploys.topic(): the socket subscribed it already
    to = System.system_time(:millisecond)

    reply =
      case list(to - @max_window_ms, to) do
        {:ok, l} -> %{deploys: l}
        {:error, e} -> %{deploys: [], error: e}
      end

    {:ok, reply, socket}
  end

  @impl true
  def handle_info({:deploy, row}, socket) do
    push(socket, "deploy", row)
    {:noreply, socket}
  end

  @impl true
  def handle_in("list", %{"from" => f, "to" => t}, socket) when is_integer(f) and is_integer(t) and t > f and t - f <= @max_window_ms do
    reply =
      case list(f, t) do
        {:ok, l} -> {:ok, %{deploys: l}}
        {:error, e} -> {:error, %{error: e}}
      end

    {:reply, reply, socket}
  end

  def handle_in(event, params, socket),
    do: {:reply, {:error, %{error: "deploys: cannot #{inspect(event)} with #{inspect(params)}; list takes from and to, unix ms, at most 31 days apart"}}, socket}

  defp list(f, t) do
    if Process.whereis(Tape.db()) do
      case Deploys.list(f, t) do
        {:ok, l} -> {:ok, l}
        {:error, e} -> {:error, "deploys: " <> Tape.message(e)}
      end
    else
      {:error, "no deploy history: OBJECTIVES_PG_URL is not set"}
    end
  end
end
