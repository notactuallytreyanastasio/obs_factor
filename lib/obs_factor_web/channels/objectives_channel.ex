defmodule ObsFactorWeb.ObjectivesChannel do
  @moduledoc """
  `objectives`: the join reply is `%{objectives: list}` (`Objectives.list/0`)
  or `%{error: reason}` (no store, Postgres down: the join still succeeds,
  so the changes arrive once it is back). Then an `objective` push with the
  public row for every change, whoever made it (`ObsFactor.Objectives`
  "Live"). When the store starts failing, a `list` push `%{error: reason}`
  (keep the rows, say they may be stale); when it answers again, a `list`
  push with the whole `%{objectives: list}`.

  Writes, as pushes answered with `{:ok, row}` or `{:error, %{error: reason}}`:

    * `pin`  `%{node, title, note, by}`
    * `act`  `%{id, action: look | done | reopen, note, by}`

  Their effect reaches every viewer as an `objective` push; the reply is
  only for the one who asked.
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.Objectives

  @impl true
  def join("objectives", _params, socket) do
    current = list()
    send(self(), :after_join)
    {:ok, current, assign(socket, :joined_with, current)}
  end

  @impl true
  # a change between the list above and the PubSub subscription: send the list again
  def handle_info(:after_join, socket) do
    case list() do
      same when same == socket.assigns.joined_with -> :ok
      changed -> push(socket, "list", changed)
    end

    {:noreply, assign(socket, :joined_with, nil)}
  end

  def handle_info({:objective, row}, socket) do
    push(socket, "objective", row)
    {:noreply, socket}
  end

  # the store failing, or answering again: a `list` push, as at join
  def handle_info({:objectives_error, reason}, socket) do
    push(socket, "list", %{error: reason})
    {:noreply, socket}
  end

  def handle_info({:objectives_list, list}, socket) do
    push(socket, "list", %{objectives: list})
    {:noreply, socket}
  end

  @impl true
  # identities: `by` is the GitHub login when there is one (ObsFactorWeb.Identity.sign/2)
  def handle_in("pin", params, socket) when is_map(params),
    do: {:reply, write(fn -> Objectives.pin(ObsFactorWeb.Identity.sign(params, socket.assigns[:identity])) end), socket}

  def handle_in("act", %{"id" => id, "action" => action} = params, socket)
      when is_integer(id) and action in ~w(look done reopen),
      do: {:reply, write(fn -> Objectives.act(id, action, ObsFactorWeb.Identity.sign(params, socket.assigns[:identity])) end), socket}

  def handle_in("act", params, socket),
    do:
      {:reply,
       {:error,
        %{
          error: "act needs an integer id and action look, done or reopen, got #{inspect(params)}"
        }}, socket}

  def handle_in(event, _params, socket),
    do: {:reply, {:error, %{error: "unknown event #{inspect(event)}"}}, socket}

  defp list do
    if Objectives.enabled?() do
      case Objectives.list() do
        {:ok, list} -> %{objectives: list}
        {:error, e} -> %{error: e}
      end
    else
      %{error: "no objectives store: OBJECTIVES_PG_URL is not set"}
    end
  end

  defp write(call) do
    if Objectives.enabled?() do
      case call.() do
        {:ok, row} -> {:ok, row}
        {:error, e} -> {:error, %{error: e}}
      end
    else
      {:error, %{error: "no objectives store: OBJECTIVES_PG_URL is not set"}}
    end
  end
end
