defmodule ObsFactorWeb.AlertsChannel do
  @moduledoc """
  `alerts`: the routes alerts go out on (`ObsFactor.Alerts`), for the
  Alerts panel (alerts.js).

  The join reply is `%{routes, filters, dedup_minutes, allow_private}`
  (routes with a `url_hint`, never the URL), or `%{error}` when there is no
  objectives database; the join succeeds either way.

  Pushes, answered `{:ok, reply}` or `{:error, %{error}}`:

    * `routes` `%{}`: `%{routes}`
    * `save_route` `%{name, url, min_severity, apps, filter_id, quiet_from,
      quiet_to, dedup_minutes, enabled, by}` (with `id`: change one; a
      blank `url` keeps it): `%{route}`
    * `delete_route` `%{id}`: `%{deleted: id}`
    * `test_route` `%{id}`: `%{sent: true}` once the webhook answered 2xx,
      or the error; the result is recorded on the route either way

  Every change, and every delivery, is followed by a `routes` push
  `%{routes}` to everyone on the topic.
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.{Alerts, Tape}

  @impl true
  def join("alerts", _params, socket) do
    # the channel is subscribed to "alerts" on ObsFactor.PubSub, where
    # Alerts.broadcast/1 sends {:alert_routes, list}
    reply =
      if Tape.enabled?() do
        case Alerts.list() do
          {:ok, routes} ->
            %{routes: routes, filters: ok_or(ObsFactor.WireFilters.list(), []), dedup_minutes: Alerts.default_dedup_minutes(),
              allow_private: Application.get_env(:obs_factor, :alert_allow_private_hosts, false) == true}

          {:error, e} ->
            %{error: "alerts: " <> Tape.message(e)}
        end
      else
        %{error: "no alerts: OBJECTIVES_PG_URL is not set"}
      end

    {:ok, reply, socket}
  end

  @impl true
  def handle_info({:alert_routes, list}, socket) do
    push(socket, "routes", %{routes: list})
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_in("routes", _, socket), do: {:reply, answer(Alerts.list(), :routes), socket}

  # identities (ObsFactorWeb.Identity): routes are an operator's to change
  def handle_in(event, params, socket) when event in ~w(save_route delete_route test_route) and
                                              not is_map_key(socket.assigns, :__checked__) do
    case ObsFactorWeb.Identity.authorize(socket.assigns[:identity], event_action(event), []) do
      :ok -> handle_in(event, params, Phoenix.Socket.assign(socket, :__checked__, true))
      {:error, why} -> {:reply, {:error, %{error: why}}, socket}
    end
  end

  def handle_in("save_route", params, socket) when is_map(params), do: {:reply, changed(Alerts.save(params), :route), socket}

  def handle_in("delete_route", %{"id" => id}, socket), do: {:reply, changed(Alerts.delete(id), :deleted), socket}

  # a webhook can take 10 s to answer: the reply comes from a task
  def handle_in("test_route", %{"id" => id}, socket) when is_integer(id) do
    ref = socket_ref(socket)

    Task.Supervisor.start_child(ObsFactor.TaskSupervisor, fn ->
      result = Alerts.test_send(id)
      Phoenix.Channel.reply(ref, if(result == :ok, do: {:ok, %{sent: true}}, else: {:error, %{error: Tape.message(elem(result, 1))}}))
    end)

    {:noreply, socket}
  end

  def handle_in(event, params, socket),
    do: {:reply, {:error, %{error: "alerts: cannot #{inspect(event)} with #{inspect(params)}"}}, socket}

  defp changed({:ok, _} = ok, key) do
    Alerts.broadcast()
    answer(ok, key)
  end

  defp changed(e, key), do: answer(e, key)

  defp answer({:ok, v}, key), do: {:ok, %{key => v}}
  defp answer({:error, e}, _), do: {:error, %{error: Tape.message(e)}}

  defp ok_or({:ok, v}, _), do: v
  defp ok_or(_, d), do: d

  defp event_action("save_route"), do: "save_alert_route"
  defp event_action("delete_route"), do: "delete_alert_route"
  defp event_action("test_route"), do: "test_alert_route"
end
