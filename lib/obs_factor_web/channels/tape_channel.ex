defmodule ObsFactorWeb.TapeChannel do
  @moduledoc """
  `tape`: the replay (`ObsFactor.Tape`) and the Fires panel
  (`ObsFactor.Insights`).

  The join reply is `%{range: %{from, to, frames}, tick_ms}`, or
  `%{error: reason}` when there is no tape (no objectives store) or
  Postgres does not answer; the join succeeds either way. Then a `tick`
  push per frame written: `%{at, alerts, warns, down, blocked, rps,
  err_rps, fires}` (fires: how many attention lines), so the timeline's
  live edge grows.

  Reads, as pushes answered with `{:ok, reply}` or `{:error, %{error}}`:

    * `index` `%{from, to, buckets}`: the timeline strip (`Tape.index/3`)
    * `frame` `%{at}`: `%{at, next, snapshot}`, the snapshot as it was then and
      when the next frame is (nil: this is the newest)
    * `marks` `%{from, to}`: `%{marks: [[at, kind, id, node, severity, title, by]]}`
    * `insights` `%{from, to}`: `ObsFactor.Insights.compute/2`

  Times are unix milliseconds. A window may be at most 31 days.
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.{Insights, Tape}

  @max_window_ms 31 * 86_400_000

  @impl true
  def join("tape", _params, socket) do
    reply =
      if Tape.enabled?() do
        case Tape.range() do
          {:ok, r} -> %{range: r, tick_ms: Application.get_env(:obs_factor, :tick_ms)}
          {:error, e} -> %{error: "tape: " <> Tape.message(e)}
        end
      else
        %{error: "no tape: OBJECTIVES_PG_URL is not set"}
      end

    {:ok, reply, socket}
  end

  @impl true
  def handle_info({:tape_frame, tick}, socket) do
    push(socket, "tick", tick)
    {:noreply, socket}
  end

  @impl true
  def handle_in(event, params, socket) do
    {:reply, if(Tape.enabled?(), do: read(event, params), else: {:error, %{error: "no tape: OBJECTIVES_PG_URL is not set"}}), socket}
  end

  defp read("index", %{"from" => f, "to" => t, "buckets" => b}) when is_integer(b) and b in 1..2000,
    do: window(f, t, fn f, t -> Tape.index(f, t, b) end)

  defp read("frame", %{"at" => at}) when is_integer(at) do
    case Tape.frame(at) do
      {:ok, at, json, next} -> {:ok, %{at: at, next: next, snapshot: Jason.Fragment.new(json)}}
      :none -> {:error, %{error: "the tape is empty"}}
      {:error, e} -> {:error, %{error: Tape.message(e)}}
    end
  end

  defp read("marks", %{"from" => f, "to" => t}), do: window(f, t, fn f, t -> wrap(Tape.marks(f, t), :marks) end)
  defp read("insights", %{"from" => f, "to" => t}), do: window(f, t, &Insights.compute/2)

  defp read(event, params),
    do: {:error, %{error: "tape: cannot #{inspect(event)} with #{inspect(params)}"}}

  defp window(f, t, fun) when is_integer(f) and is_integer(t) and t > f and t - f <= @max_window_ms do
    case fun.(f, t) do
      {:ok, r} -> {:ok, r}
      {:error, e} -> {:error, %{error: Tape.message(e)}}
    end
  end

  defp window(f, t, _),
    do: {:error, %{error: "a window is two integer unix ms times, from before to, at most 31 days: got #{inspect(f)}..#{inspect(t)}"}}

  defp wrap({:ok, v}, key), do: {:ok, %{key => v}}
  defp wrap(e, _), do: e
end
