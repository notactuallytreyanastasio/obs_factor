defmodule ObsFactorWeb.SLOChannel do
  @moduledoc """
  `slo`: error budgets per app (`ObsFactor.SLOs`), for the board's SLO tab.

  The join reply is `%{reports: [report], thresholds: %{"7" => %{fast,
  slow}, "30" => ...}}`, computed at the join, or `%{error: reason}` when
  there is no objectives store or Postgres does not answer; the join
  succeeds either way. Then a `status` push `%{reports}` after every
  evaluation (once a minute) and after every write.

  Writes, replied with `{:ok, %{target}}` / `{:ok, %{deleted: node}}` or
  `{:error, %{error}}`:

    * `save` `%{node, availability, window_days, latency_ms, latency_target, by}`
    * `delete` `%{node}`

  A report: `%{node, label, window_days, target, thresholds, coverage:
  %{window_ms, from, to, covered_ms, tape_from, note}, availability:
  objective, latency: objective | nil, burning, note}`, an objective
  `%{target, sli, requests, bad, budget_left_pct, burn: %{"5m", "1h",
  "30m", "6h"}, fast, slow}`. Times are unix milliseconds.
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.{SLOs, Tape}

  @impl true
  def join("slo", _params, socket) do
    # a channel is subscribed to its own topic on ObsFactor.PubSub: the
    # server's {:slo_status, reports} arrives in handle_info
    th = %{"7" => SLOs.thresholds(7), "30" => SLOs.thresholds(30)}

    reply =
      if Tape.enabled?() do
        case SLOs.report(System.system_time(:millisecond)) do
          {:ok, reports} -> %{reports: reports, thresholds: th}
          {:error, e} -> %{error: "slo: " <> Tape.message(e), thresholds: th}
        end
      else
        %{error: "no SLOs: OBJECTIVES_PG_URL is not set", thresholds: th}
      end

    {:ok, reply, socket}
  end

  @impl true
  def handle_info({:slo_status, reports}, socket) do
    push(socket, "status", %{reports: reports})
    {:noreply, socket}
  end

  @impl true
  def handle_in("save", params, socket) when is_map(params),
    do: {:reply, write(fn -> SLOs.save(params) end, :target), socket}

  def handle_in("delete", %{"node" => node}, socket),
    do: {:reply, write(fn -> SLOs.delete(node) end, :deleted), socket}

  def handle_in(event, params, socket),
    do: {:reply, {:error, %{error: "slo: cannot #{inspect(event)} with #{inspect(params)}"}}, socket}

  # a write, then everyone on the topic gets the reports again: from the
  # server when it runs (it also starts the new target's flags), else here
  defp write(fun, key) do
    if Tape.enabled?() do
      case fun.() do
        {:ok, v} ->
          refresh()
          {:ok, %{key => v}}

        {:error, e} ->
          {:error, %{error: Tape.message(e)}}
      end
    else
      {:error, %{error: "no SLOs: OBJECTIVES_PG_URL is not set"}}
    end
  end

  defp refresh do
    if GenServer.whereis(SLOs) do
      _ = SLOs.evaluate()
    else
      with {:ok, reports} <- SLOs.report(System.system_time(:millisecond)),
           do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, SLOs.topic(), {:slo_status, reports})
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
