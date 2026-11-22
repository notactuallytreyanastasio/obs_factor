defmodule ObsFactor.Feeds do
  @moduledoc """
  Data that has to be fetched to be live (the observer's own BEAM, a node's
  history, a build's log, a sub-app's `/observer/...` over HTTP) is fetched
  by one feed process per PubSub topic, however many browsers watch it.

    * A feed starts when its first subscriber joins (`subscribe/2`), fetches
      at once and then every `interval_ms`, and broadcasts each result on its
      topic on `ObsFactor.PubSub` as `{:feed, topic, payload}`, where payload
      is `%{at: iso8601, data: data}` or, when the fetch failed,
      `%{at: iso8601, error: reason}`. A raise or exit in the fetch is an error
      too, with its message.
    * The last payload is kept and handed to each new subscriber, so a
      browser that joins sees data at once instead of waiting a period.
    * Subscribers are monitored (they are channel processes). When the last
      one goes, the feed stops `linger_ms` later (10 s; config
      `:obs_factor, :feeds_linger_ms`) unless someone joins in between.
    * A fetch runs in a task under `ObsFactor.TaskSupervisor`, so a slow one
      never blocks a join; while one is in flight the next is skipped.
    * `refetch/1` and `refetch_prefix/1` fetch at once, outside the
      interval (after an action, so its effect shows without waiting).

  ## Adding a view

  A topic is turned into a spec `{module, args, interval_ms}` by
  `ObsFactor.Feeds.Views.spec/1`, which asks each resolver module in turn:
  the built-in `ObsFactor.Feeds.Views`, then every module listed in
  `config :obs_factor, :feed_views, [MyResolver]`. A resolver implements
  `c:ObsFactor.Feeds.View.resolve/1`: given the topic it returns
  `{:ok, {module, args, interval_ms}}`, `{:error, reason}` (the topic is
  this resolver's but wrong, e.g. an unknown node: the join is refused with
  the reason) or `:pass` (not mine). `module.fetch(args)` returns
  `{:ok, data}` or `{:error, reason}`; data must encode to JSON. That is the
  whole contract: `ObsFactorWeb.FeedChannel` joins any topic a resolver
  claims, and nothing else needs to change.
  """

  alias ObsFactor.Feeds.Feed

  @registry ObsFactor.Feeds.Registry
  @supervisor ObsFactor.Feeds.Supervisor

  @type spec :: {module(), term(), pos_integer()}

  @doc "The registry and the supervisor, for the application's children."
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  @doc """
  Subscribes the calling process (or `pid`) to `topic`'s feed, starting it
  with `spec` if it is not running. Returns `{:ok, last}`, where `last` is
  the feed's latest payload or nil before its first fetch has finished. The
  caller must subscribe itself to `topic` on `ObsFactor.PubSub` to receive
  the broadcasts (a channel on that topic already is).
  """
  @spec subscribe(String.t(), spec(), pid()) :: {:ok, map() | nil}
  def subscribe(topic, {mod, _args, interval} = spec, pid \\ self())
      when is_binary(topic) and is_atom(mod) and is_integer(interval) and interval > 0 do
    try do
      GenServer.call(feed(topic, spec), {:subscribe, pid})
    catch
      # it stopped between the lookup and the call (its linger ran out): once more
      :exit, {reason, _} when reason in [:noproc, :normal] ->
        GenServer.call(feed(topic, spec), {:subscribe, pid})
    end
  end

  @doc "The latest payload of `topic`'s feed; nil before its first fetch or when it is not running."
  def last(topic) do
    case whereis(topic) do
      nil -> nil
      pid -> GenServer.call(pid, :last)
    end
  catch
    :exit, _ -> nil
  end

  @doc "The pid of `topic`'s feed, or nil."
  def whereis(topic) do
    case Registry.lookup(@registry, topic) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Fetches `topic` again now, outside its interval (after an action, so the
  floor shows its effect at once). A fetch in flight is followed by one
  more as soon as it finishes. No-op when the feed is not running.
  """
  def refetch(topic) do
    case whereis(topic) do
      nil -> :ok
      pid -> send(pid, :refetch) && :ok
    end
  end

  @doc "`refetch/1` for every running feed whose topic starts with `prefix`; returns those topics."
  def refetch_prefix(prefix) when is_binary(prefix) do
    for topic <- topics(), String.starts_with?(topic, prefix) do
      refetch(topic)
      topic
    end
  end

  @doc "Topics with a running feed."
  def topics, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp feed(topic, spec) do
    case DynamicSupervisor.start_child(@supervisor, {Feed, {topic, spec}}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc false
  def via(topic), do: {:via, Registry, {@registry, topic}}

  @doc false
  def linger_ms, do: Application.get_env(:obs_factor, :feeds_linger_ms, 10_000)
end

defmodule ObsFactor.Feeds.View do
  @moduledoc "A resolver of feed topics; see `ObsFactor.Feeds` \"Adding a view\"."
  @callback resolve(topic :: String.t()) ::
              {:ok, ObsFactor.Feeds.spec()} | {:error, String.t()} | :pass
end

defmodule ObsFactor.Feeds.Feed do
  @moduledoc "One topic's feed: see `ObsFactor.Feeds`."
  use GenServer, restart: :temporary

  def start_link({topic, spec}),
    do: GenServer.start_link(__MODULE__, {topic, spec}, name: ObsFactor.Feeds.via(topic))

  @impl true
  def init({topic, {mod, args, interval}}) do
    send(self(), :fetch)

    {:ok,
     %{
       topic: topic,
       mod: mod,
       args: args,
       interval: interval,
       subs: %{},
       last: nil,
       task: nil,
       again: false,
       stop: nil
     }}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, st) do
    st =
      if Enum.any?(st.subs, fn {_, p} -> p == pid end),
        do: st,
        else: %{st | subs: Map.put(st.subs, Process.monitor(pid), pid)}

    {:reply, {:ok, st.last}, cancel_stop(st)}
  end

  def handle_call(:last, _from, st), do: {:reply, st.last, st}

  @impl true
  def handle_info(:fetch, %{task: nil} = st) do
    Process.send_after(self(), :fetch, st.interval)
    {:noreply, start_fetch(st)}
  end

  # the previous fetch is still running: skip this period
  def handle_info(:fetch, st) do
    Process.send_after(self(), :fetch, st.interval)
    {:noreply, st}
  end

  # out of turn (Feeds.refetch/1): the periodic timer is left as it is
  def handle_info(:refetch, %{task: nil} = st), do: {:noreply, start_fetch(st)}
  def handle_info(:refetch, st), do: {:noreply, %{st | again: true}}

  def handle_info({ref, result}, %{task: ref} = st) do
    Process.demonitor(ref, [:flush])
    payload = Map.put(result, :at, DateTime.utc_now() |> DateTime.to_iso8601())
    Phoenix.PubSub.broadcast(ObsFactor.PubSub, st.topic, {:feed, st.topic, payload})
    {:noreply, after_fetch(%{st | task: nil, last: payload})}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: ref} = st) do
    payload = %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      error: "fetch crashed: " <> inspect(reason, limit: 20)
    }

    Phoenix.PubSub.broadcast(ObsFactor.PubSub, st.topic, {:feed, st.topic, payload})
    {:noreply, after_fetch(%{st | task: nil, last: payload})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, st) do
    subs = Map.delete(st.subs, ref)
    st = %{st | subs: subs}
    {:noreply, if(subs == %{}, do: schedule_stop(st), else: st)}
  end

  def handle_info({:linger_over, ref}, %{stop: ref, subs: subs} = st) when subs == %{},
    do: {:stop, :normal, st}

  def handle_info({:linger_over, _}, st), do: {:noreply, st}

  defp start_fetch(st) do
    %{mod: mod, args: args} = st
    task = Task.Supervisor.async_nolink(ObsFactor.TaskSupervisor, fn -> run(mod, args) end)
    %{st | task: task.ref, again: false}
  end

  # a refetch asked for while that fetch was running: its answer may predate the action
  defp after_fetch(%{again: true} = st), do: start_fetch(st)
  defp after_fetch(st), do: st

  defp schedule_stop(st) do
    ref = make_ref()
    Process.send_after(self(), {:linger_over, ref}, ObsFactor.Feeds.linger_ms())
    %{st | stop: ref}
  end

  defp cancel_stop(st), do: %{st | stop: nil}

  defp run(mod, args) do
    case mod.fetch(args) do
      {:ok, data} ->
        %{data: data}

      {:error, reason} when is_binary(reason) ->
        %{error: reason}

      {:error, reason} ->
        %{error: inspect(reason, limit: 20)}

      other ->
        %{
          error:
            "#{inspect(mod)}.fetch/1 returned #{inspect(other, limit: 10)}, not {:ok, _} or {:error, _}"
        }
    end
  rescue
    e -> %{error: Exception.message(e)}
  catch
    kind, reason -> %{error: "#{kind}: #{inspect(reason, limit: 20)}"}
  end
end
