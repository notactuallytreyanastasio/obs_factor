defmodule ObsFactorWeb.FeedChannel do
  @moduledoc """
  Any topic a feed serves (`observer:*`, `history:*`, `builds:*`; see
  `ObsFactor.Feeds.Views`). Joining subscribes to the topic's feed, starting
  it if nobody else watches it. The join reply is the feed's last payload
  (`%{at, data}` or `%{at, error}`), or `%{}` before its first fetch; then a
  `feed` push with each payload. A topic no resolver claims is refused with
  `%{reason: ...}`, and so is a join past the feed limits
  (`ObsFactor.Feeds`: at most 150 per socket, 1000 feeds in all).

  On `observer:*` topics the browser may push `action` (see `handle_in/3`).
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.ObserverProxy

  @impl true
  def join(topic, _params, socket) do
    with {:ok, spec} <- ObsFactor.Feeds.Views.spec(topic),
         :ok <- ObsFactor.Feeds.claim_join(socket.transport_pid),
         {:ok, last} <- ObsFactor.Feeds.subscribe(topic, spec) do
      # a payload broadcast before PubSub subscribed this process is caught in :after_join
      send(self(), :after_join)
      {:ok, last || %{}, assign(socket, :joined_with, last)}
    else
      {:error, reason} -> ObsFactorWeb.Log.refuse(reason)
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

  # An action on the topic's node and member: `{path, params, by}`, e.g.
  # `{"path": "proc/0.238.0/gc", "by": "dave (floor)"}`. It goes through
  # `ObsFactor.ObserverProxy.call/5` exactly as `POST /api/nodes/:id/observer/*path`
  # does: forwarded with OBSERVER_ACTIONS_TOKEN and x-factory-by, logged,
  # broadcast on "actions", and every feed of that node and member refetched.
  # Replied with the engine's 2xx body, else `{error, status}`. A payload
  # refused here (no path, params not an object, not an object at all) is
  # recorded on "actions" too, with what could be read of it.
  @impl true
  def handle_in("action", payload, %{topic: "observer:" <> _ = topic} = socket) do
    {:ok, node, member, _view} = ObsFactor.Feeds.ObserverViews.parse(topic)
    path = if is_map(payload), do: payload["path"]
    params = if is_map(payload), do: Map.get(payload, "params") || %{}
    # identities: a GitHub login signs as itself, whatever the payload says
    identity = socket.assigns[:identity]
    by = if is_map(payload), do: ObserverProxy.clean_by(ObsFactorWeb.Identity.by(identity, payload["by"]))

    result =
      cond do
        not is_binary(path) or path == "" ->
          {400,
           %{
             "error" =>
               "action needs {path, params, by}, e.g. {\"path\": \"proc/0.238.0/gc\", \"by\": \"you\"}; got #{inspect(payload, limit: 5)}"
           }}

        not is_map(params) ->
          {400, %{"error" => "action params must be an object, got #{inspect(params, limit: 5)}"}}

        # identities: only an operator acts (ObsFactorWeb.Identity), refused like a bad payload
        true ->
          case ObsFactorWeb.Identity.authorize(identity, "observer_action", by: by, node: node, path: path) do
            :ok -> nil
            {:error, why} -> {403, %{"error" => why}}
          end
      end

    {status, body} =
      case result do
        # refused here, before the proxy: recorded like every other action
        {_, _} = refused ->
          segments = if is_binary(path) and path != "", do: String.split(path, "/"), else: []
          ObserverProxy.record_action(node, segments, params, [member: member, by: by], refused)
          refused

        nil ->
          ObserverProxy.call("POST", node, String.split(path, "/"), Map.delete(params, "by"),
            member: member,
            by: by
          )
      end

    if status in 200..299,
      do: {:reply, {:ok, body}, socket},
      else: {:reply, {:error, %{error: body["error"] || "status #{status}", status: status}}, socket}
  end

  def handle_in(event, _payload, socket),
    do:
      {:reply, {:error, %{error: "#{inspect(event)} is not an event of #{socket.topic}"}}, socket}
end
