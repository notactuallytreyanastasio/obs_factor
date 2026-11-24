defmodule ObsFactorWeb.EvidenceChannel do
  @moduledoc """
  `evidence`: what a BEAM was doing when the wire flagged it
  (`ObsFactor.Evidence`).

  The join reply is `%{}`, or `%{error: reason}` when there is no evidence
  taker or no tape; the join succeeds either way. Then a `captured` push
  per capture stored, and again when a later wire item is linked to it:
  `%{id, at, app, member, address, hot, links}` (`index` below).

  Reads, answered `{:ok, reply}` or `{:error, %{error}}`:

    * `index` `%{from, to}`: `%{evidence: [entry]}`, the captures linked to
      wire items in `[from, to]` (unix ms, at most 31 days), newest first,
      at most 500, without their bodies
    * `get` `%{id}` or `%{wire_id}`: `%{evidence: entry with body}`, one
      capture whole; `{error}` when there is none
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.{Evidence, Tape}

  @max_window_ms 31 * 86_400_000

  @impl true
  def join("evidence", _params, socket) do
    reply =
      cond do
        not Tape.enabled?() -> %{error: "no evidence: OBJECTIVES_PG_URL is not set, so there is no tape to keep it"}
        GenServer.whereis(Evidence) == nil -> %{error: "no evidence: the evidence taker is not running (no collectors?)"}
        true -> %{}
      end

    {:ok, reply, socket}
  end

  @impl true
  def handle_info({:evidence, entry}, socket) do
    push(socket, "captured", entry)
    {:noreply, socket}
  end

  @impl true
  def handle_in("index", %{"from" => f, "to" => t}, socket)
      when is_integer(f) and is_integer(t) and t > f and t - f <= @max_window_ms do
    {:reply, answer(Evidence.index(f, t), &%{evidence: &1}), socket}
  end

  def handle_in("index", _, socket),
    do: {:reply, {:error, %{error: "index needs from and to, integer unix ms, from first, at most 31 days"}}, socket}

  def handle_in("get", %{"id" => id}, socket), do: {:reply, answer(Evidence.get(id), &%{evidence: &1}), socket}
  def handle_in("get", %{"wire_id" => id}, socket), do: {:reply, answer(Evidence.for_wire(id), &%{evidence: &1}), socket}
  def handle_in("get", _, socket), do: {:reply, {:error, %{error: "get needs id or wire_id"}}, socket}

  def handle_in(event, _, socket), do: {:reply, {:error, %{error: "#{inspect(event)} is not an event of evidence"}}, socket}

  defp answer({:ok, v}, f), do: {:ok, f.(v)}
  defp answer(:none, _), do: {:error, %{error: "no evidence for that"}}
  defp answer({:error, e}, _), do: {:error, %{error: Tape.message(e)}}
end
