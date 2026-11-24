defmodule FactoryReport.PubSub do
  @moduledoc """
  Every `Phoenix.PubSub` server running in this VM: its topics and who is
  subscribed to them. The report's `pubsub` section and the observer's
  `GET /observer/pubsub` read it.

  What a PubSub server is, checked by starting one on phoenix_pubsub 2.4.1
  (Elixir 1.18.4, OTP 28), not read from memory: `{Phoenix.PubSub, name:
  MyApp.PubSub}` starts `MyApp.PubSub.Supervisor`, which starts a
  `Registry` registered as `MyApp.PubSub` itself (keys `:duplicate`, or
  `{:duplicate, :key}` with `group_by: :key`; partitions from
  `:registry_size`, else `:pool_size`, else `ceil(schedulers / 4)`) and the
  adapter, registered as `MyApp.PubSub.Adapter`. The registry's metadata
  holds `pubsub: {Phoenix.PubSub.PG2, MyApp.PubSub.Adapter, Phoenix.PubSub}`
  (adapter, adapter name, dispatcher). So a server is found by asking every
  registered name for `Registry.meta(name, :pubsub)`, and a subscription is
  one registry entry: key the topic, value the subscriber's metadata (a
  channel's fastlane `[Phoenix.Channel.Server | {transport, serializer,
  intercepts}]`, else `nil`).

  Topics: `Phoenix.PubSub.subscribe/3` takes only binaries, but the
  registry takes any term (`Registry.register/3` straight on it), so a topic
  is written as itself when it is a valid string and with `inspect/2`
  otherwise, cut at 120 bytes either way.

  The report names no topic. A topic carries ids as often as not
  (`room:user-1234`, `lv:phx-F_xUq1abc`), and the report promises no user
  identifiers and no full channel topics, so its `top` is by **pattern**:
  the topic with ids blanked (`pattern/1`, `room:#`), with how many topics
  and subscriptions each pattern holds. That is also the more useful
  ranking: ten thousand `room:N` topics of one subscriber each are one row,
  not ten thousand rows that never make the top 25. Whole topics are in
  the observer's `GET /observer/pubsub`, on demand, behind the observer's
  read authorization, as process names and pids are.

  Cost: discovery is one ETS lookup per registered name. Counting is
  `Registry.count/1` (one `:ets.info/2` per partition). Topics are counted
  by selecting every `{topic, pid}` and grouping them, which is linear in
  subscriptions: past #{100_000} subscriptions on one server the topics are
  not walked, only counted (`counts_only` says so), because the report is
  read every 5 s.

  ## Counting broadcasts (opt-in)

  Phoenix.PubSub emits no telemetry for a broadcast, so how often a topic
  is published to cannot be seen from outside the app. `broadcast/3` is
  `Phoenix.PubSub.broadcast/3` that first counts one occurrence in the
  report's `pubsub.broadcast` stream, under the topic with its ids blanked
  (`"room:42"` → `"room:#"`), so the stream stays a small fixed set of names.
  """

  alias FactoryReport.{Observer, Streams}

  @walk_limit 100_000
  @max_servers 10
  @top 25
  @max_topic 120
  @view_limit 100
  @view_limit_max 1_000
  @subscribers_max 200
  @sorts ~w(subscriptions topic)

  @doc false
  def walk_limit, do: @walk_limit

  # ---- the report section ----------------------------------------------------

  @doc """
  The report's `pubsub` section: `{servers, cut}`, one map per server (at
  most #{@max_servers}, by name), each with its top #{@top} topic patterns.
  """
  def section do
    {shown, cut} = servers() |> Enum.split(@max_servers)
    {Enum.map(shown, &summary(&1, @top)), length(cut)}
  end

  # ---- the observer read -----------------------------------------------------

  @doc false
  # GET /observer/pubsub[?server=&topic=&limit=&sort=]. Throws {:bad, status,
  # message} as the observer's other reads do.
  def read(params) do
    case {params["server"], params["topic"]} do
      {nil, nil} ->
        {limit, sort} = list_params!(params)
        {shown, cut} = servers() |> Enum.split(@max_servers)

        %{
          "servers" => Enum.map(shown, &listing(&1, limit, sort)),
          "servers_cut" => length(cut),
          "limit" => limit,
          "sort" => sort,
          "walk_limit" => @walk_limit
        }

      {server, nil} when is_binary(server) ->
        {limit, sort} = list_params!(params)

        %{
          "servers" => [listing(server!(server), limit, sort)],
          "servers_cut" => 0,
          "limit" => limit,
          "sort" => sort,
          "walk_limit" => @walk_limit
        }

      {server, topic} when is_binary(server) and is_binary(topic) ->
        subscribers(server!(server), topic)

      {nil, _} ->
        bad(400, "topic= needs server= too (a server's name as the list gives it, e.g. MyApp.PubSub)")

      _ ->
        bad(400, "server and topic must be strings")
    end
  end

  defp list_params!(params) do
    sort = Map.get(params, "sort", "subscriptions")
    sort in @sorts || bad(400, "sort must be one of #{Enum.join(@sorts, ", ")}")

    limit =
      case Map.get(params, "limit") do
        nil ->
          @view_limit

        n when is_integer(n) and n in 1..@view_limit_max ->
          n

        text when is_binary(text) ->
          case Integer.parse(text) do
            {n, ""} when n in 1..@view_limit_max -> n
            _ -> bad(400, "limit must be an integer from 1 to #{@view_limit_max}")
          end

        _ ->
          bad(400, "limit must be an integer from 1 to #{@view_limit_max}")
      end

    {limit, sort}
  end

  defp server!(text) do
    Enum.find(servers(), &(&1.text == text)) ||
      bad(404, "no PubSub server #{inspect(Streams.text(text, 120))} in this VM (#{servers() |> Enum.map_join(", ", & &1.text) |> then(&if(&1 == "", do: "it has none", else: "it has " <> &1))})")
  end

  defp listing(s, limit, sort) do
    walked = walk(s)
    base = head(s, walked)

    {topics, cut} =
      case walked do
        {:ok, by_topic, _pids} ->
          by_topic
          |> Enum.map(fn {text, n} -> %{"topic" => text, "pattern" => blank(text), "subscriptions" => n} end)
          |> Enum.sort_by(fn t -> if sort == "topic", do: {t["topic"]}, else: {-t["subscriptions"], t["topic"]} end)
          |> Enum.split(limit)
          |> then(fn {shown, cut} -> {shown, length(cut)} end)

        :too_many ->
          {[], 0}
      end

    Map.merge(base, %{"topics_list" => topics, "topics_cut" => cut})
  end

  # One topic's subscribers. A topic nobody is subscribed to is 200 with no
  # subscribers, not 404: a feed asks every second and topics come and go.
  defp subscribers(s, topic) do
    entries =
      case Registry.lookup(s.name, topic) do
        [] -> by_text(s, topic)
        found -> found
      end

    per_pid =
      Enum.reduce(entries, %{}, fn {pid, value}, acc ->
        Map.update(acc, pid, {1, fastlane?(value)}, fn {n, f} -> {n + 1, f or fastlane?(value)} end)
      end)

    dict? = dict_key?()

    rows =
      per_pid
      |> Enum.flat_map(fn {pid, {n, fastlane}} ->
        case Observer.summary(pid, dict?) do
          nil -> []
          sum -> [sum |> Map.delete("supervisor?") |> Map.merge(%{"entries" => n, "fastlane" => fastlane}) |> Map.merge(kind(pid))]
        end
      end)
      |> Enum.sort_by(&{-(&1["message_queue_len"] || 0), -(&1["memory"] || 0), &1["pid"]})

    {shown, cut} = Enum.split(rows, @subscribers_max)

    %{
      "server" => s.text,
      "topic" => topic_text(topic),
      "subscriptions" => length(entries),
      "subscribers" => shown,
      "subscribers_cut" => length(cut),
      "subscribers_limit" => @subscribers_max
    }
  end

  # A topic that is not a binary, asked for by its text: found by walking,
  # within the walk limit.
  defp by_text(s, topic) do
    if Registry.count(s.name) > @walk_limit do
      []
    else
      for {key, pid, value} <- Registry.select(s.name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]),
          not is_binary(key),
          topic_text(key) == topic,
          do: {pid, value}
    end
  end

  # A LiveView: `$initial_call` {View, :mount, 3} and View exports
  # __live__/0 (FactoryReport.LiveViews); a channel: {Channel, :join, 3}
  # and Channel exports __intercepts__/0, which `use Phoenix.Channel`
  # defines. Both checked by running them (see the tests).
  defp kind(pid) do
    case :erlang.process_info(pid, {:dictionary, :"$initial_call"}) do
      {_, {m, :mount, 3}} when is_atom(m) ->
        if function_exported?(m, :__live__, 0),
          do: %{"kind" => "liveview", "module" => Streams.text(inspect(m))},
          else: %{"kind" => "process", "module" => nil}

      {_, {m, :join, 3}} when is_atom(m) ->
        if function_exported?(m, :__intercepts__, 0),
          do: %{"kind" => "channel", "module" => Streams.text(inspect(m))},
          else: %{"kind" => "process", "module" => nil}

      _ ->
        %{"kind" => "process", "module" => nil}
    end
  rescue
    ArgumentError -> %{"kind" => "process", "module" => nil}
  end

  defp fastlane?([Phoenix.Channel.Server | {_, _, _}]), do: true
  defp fastlane?({:fastlane, _, _, _}), do: true
  defp fastlane?(_), do: false

  defp dict_key? do
    _ = :erlang.process_info(self(), {:dictionary, :"$initial_call"})
    true
  rescue
    ArgumentError -> false
  end

  # ---- finding and walking servers --------------------------------------------

  @doc false
  # Every PubSub server in this VM, by name: %{name, text, adapter, keys, partitions}.
  def servers do
    Process.registered()
    |> Enum.flat_map(fn name ->
      case server(name) do
        nil -> []
        s -> [s]
      end
    end)
    |> Enum.sort_by(& &1.text)
  end

  @doc false
  def server(name) when is_atom(name) do
    case Registry.meta(name, :pubsub) do
      {:ok, meta} when is_tuple(meta) and tuple_size(meta) in [2, 3] and is_atom(elem(meta, 0)) ->
        {kind, partitions} = registry_shape(name)

        %{
          name: name,
          text: Streams.text(inspect(name)),
          adapter: Streams.text(inspect(elem(meta, 0))),
          keys: kind,
          partitions: partitions
        }

      _ ->
        nil
    end
  rescue
    # Not a registry: Registry.meta/2 raises for a name with no ETS table
    # of that name, and :ets raises for a private one.
    ArgumentError -> nil
  end

  # The registry's kind and partitions. Registry has no public read for
  # them; Elixir 1.18 keeps them under the key -2 of the registry's
  # own table ({kind, partitions, _}). Another shape reads as nil.
  defp registry_shape(name) do
    case :ets.lookup(name, -2) do
      [{-2, info}] when is_tuple(info) and tuple_size(info) >= 2 and is_integer(elem(info, 1)) ->
        {keys_text(elem(info, 0)), elem(info, 1)}

      _ ->
        {nil, nil}
    end
  rescue
    ArgumentError -> {nil, nil}
  end

  defp keys_text(:duplicate), do: "duplicate"
  defp keys_text({:duplicate, :key}), do: "duplicate_by_key"
  defp keys_text(:unique), do: "unique"
  defp keys_text(other), do: Streams.text(inspect(other))

  # {:ok, %{topic_text => subscriptions}, distinct pids} or :too_many.
  # Topics whose texts collide (two terms that print the same once cut)
  # are counted together.
  defp walk(s) do
    if Registry.count(s.name) > @walk_limit do
      :too_many
    else
      {by_topic, pids} =
        s.name
        |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.reduce({%{}, %{}}, fn {topic, pid}, {topics, pids} ->
          {Map.update(topics, topic, 1, &(&1 + 1)), Map.put(pids, pid, true)}
        end)

      texts = Enum.reduce(by_topic, %{}, fn {t, n}, acc -> Map.update(acc, topic_text(t), n, &(&1 + n)) end)
      {:ok, texts, map_size(pids)}
    end
  rescue
    # The registry went away between finding it and walking it.
    ArgumentError -> {:ok, %{}, 0}
  end

  defp head(s, walked) do
    subs =
      try do
        Registry.count(s.name)
      rescue
        ArgumentError -> 0
      end

    %{
      "name" => s.text,
      "adapter" => s.adapter,
      "keys" => s.keys,
      "partitions" => s.partitions,
      "subscriptions" => subs,
      "topics" => topics_of(walked),
      "subscribers" => subscribers_of(walked),
      "counts_only" =>
        if(walked == :too_many,
          do: "#{subs} subscriptions, more than the walk limit of #{@walk_limit}: topics are not walked, only subscriptions counted"
        ),
      "walk_limit" => @walk_limit
    }
  end

  defp topics_of({:ok, by_topic, _}), do: map_size(by_topic)
  defp topics_of(:too_many), do: nil
  defp subscribers_of({:ok, _, pids}), do: pids
  defp subscribers_of(:too_many), do: nil

  defp summary(s, top) do
    started = System.monotonic_time()
    walked = walk(s)

    {shown, cut} =
      case walked do
        {:ok, by_topic, _} ->
          by_topic
          |> Enum.reduce(%{}, fn {t, n}, acc -> Map.update(acc, blank(t), {1, n}, fn {k, m} -> {k + 1, m + n} end) end)
          |> Enum.sort_by(fn {p, {k, n}} -> {-n, -k, p} end)
          |> Enum.split(top)
          |> then(fn {shown, cut} ->
            {Enum.map(shown, fn {p, {k, n}} -> %{"pattern" => p, "topics" => k, "subscriptions" => n} end), length(cut)}
          end)

        :too_many ->
          {[], 0}
      end

    us = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

    s
    |> head(walked)
    |> Map.merge(%{"top" => shown, "patterns_cut" => cut, "took_ms" => Float.round(us / 1000, 2)})
  end

  @doc """
  A topic as text: a valid UTF-8 binary as itself, anything else with
  `inspect/2`; at most #{@max_topic} bytes.
  """
  def topic_text(t) when is_binary(t) do
    if String.valid?(t), do: Streams.text(t, @max_topic), else: Streams.text(inspect(t, limit: 20, printable_limit: @max_topic), @max_topic)
  end

  def topic_text(t), do: Streams.text(inspect(t, limit: 20, printable_limit: @max_topic), @max_topic)

  # ---- broadcast, counted ------------------------------------------------------

  @doc """
  `Phoenix.PubSub.broadcast/3`, counted: one occurrence in the report's
  `pubsub.broadcast` stream under `pattern(topic)`, then the broadcast.
  Returns what `Phoenix.PubSub.broadcast/3` returns. Counting never raises.

      FactoryReport.PubSub.broadcast(MyApp.PubSub, "room:42", {:new_message, msg})
  """
  def broadcast(pubsub, topic, message) do
    count(topic)
    # Phoenix.PubSub is the caller's dependency, not this library's.
    mod = Phoenix.PubSub
    mod.broadcast(pubsub, topic, message)
  end

  defp count(topic) do
    Streams.hit("pubsub.broadcast", pattern(topic), 0, false)
  catch
    _, _ -> :ok
  end

  @doc """
  A topic with what looks like an id blanked, so one stream name stands for
  every room: runs of digits, hex or UUID-like runs of 8 or more, and
  Phoenix's `phx-...` ids become `#`. `"room:42"` → `"room:#"`,
  `"user:3f2a9c1e-77b0-4c1e-9d1a-0b6f3b1e2a4c"` → `"user:#"`.
  """
  def pattern(topic), do: blank(topic_text(topic))

  defp blank(text) do
    text
    # LiveView and socket ids: phx-F_xUq1abc
    |> String.replace(~r/phx-[A-Za-z0-9_-]+/, "phx-#")
    |> String.replace(~r/[0-9a-fA-F]{8}(?:-?[0-9a-fA-F]{4}){3}-?[0-9a-fA-F]{12}|[0-9a-fA-F]*\d[0-9a-fA-F]{7,}|\d+/, "#")
  end

  defp bad(status, message), do: throw({:bad, status, message})
end
