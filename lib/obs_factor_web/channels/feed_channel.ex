defmodule ObsFactorWeb.FeedChannel do
  @moduledoc """
  Any topic a feed serves (`observer:*`, `history:*`, `builds:*`; see
  `ObsFactor.Feeds.Views`). Joining subscribes to the topic's feed, starting
  it if nobody else watches it. The join reply is the feed's last payload
  (`%{at, data}` or `%{at, error}`), or `%{}` before its first fetch; then a
  `feed` push with each payload. A topic no resolver claims is refused with
  `%{reason: ...}`.
  """
  use ObsFactorWeb, :channel

  @impl true
  def join(topic, _params, socket) do
    case ObsFactor.Feeds.Views.spec(topic) do
      {:ok, spec} ->
        {:ok, last} = ObsFactor.Feeds.subscribe(topic, spec)
        # a payload broadcast before PubSub subscribed this process is caught in :after_join
        send(self(), :after_join)
        {:ok, last || %{}, assign(socket, :joined_with, last)}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    case ObsFactor.Feeds.last(socket.topic) do
      same when same == socket.assigns.joined_with -> :ok
      nil -> :ok
      payload -> push(socket, "feed", payload)
    end

    {:noreply, assign(socket, :joined_with, nil)}
  end

  def handle_info({:feed, _topic, payload}, socket) do
    push(socket, "feed", payload)
    {:noreply, socket}
  end
end
