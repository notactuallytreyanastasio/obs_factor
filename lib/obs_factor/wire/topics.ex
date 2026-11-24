defmodule ObsFactor.Wire.Topics do
  @moduledoc """
  PubSub on the BEAM wire (`ObsFactor.Wire`): each PubSub server of each
  BEAM member, and of the observer's own VM, on the tape and as news.

  Read from the snapshot as the browser gets it (JSON, string keys): every
  BEAM node's `inside.pubsub`, or each member's when it is a cluster, and
  `snap["observer_pubsub"]`, which the ticker adds to the wire's copy of the
  snapshot (`ObsFactor.Topics.own/0`; it is not in the snapshot itself).

  On the tape (`metrics/1`): `"pubsub:<member>:<server>"` =>
  `%{app, member, server, topics, subs}`, the member keyed as the wire keys
  it (the node name of a distributed member, else the app's id;
  `"observer"` for the observer).

  News, `kind: "pubsub"`:

    * **a subscription leak**: one server's subscriptions higher at every
      minute for 30 minutes, up in each 10-minute third, by at least 20 and
      10 %. Sampled once a minute, so churn inside a minute is not a fall;
      any minute lower than the one before ends the run. Said once a run.
    * **a topic jump**: topics up by 50 and by half in one tick.

  The state is per `{member, server}`: `%{samples: [{at_ms, subs}] newest
  first, one a minute, 35 minutes of them, topics, leak}`.
  """

  @sample_ms 60_000
  @leak_ms 30 * 60_000
  @keep_ms 35 * 60_000
  @leak_min 20
  @leak_frac 0.1
  @jump_min 50
  @jump_frac 0.5

  @doc "Every `{member, server}` of the snapshot: `%{key, app, label, member, server, topics, subs}`."
  def servers(snap) do
    nodes =
      for n <- snap["nodes"] || [],
          match?(%{"inside" => %{"ok" => true, "runtime" => %{"kind" => "beam"}}}, n),
          m <- members_of(n["inside"]),
          s <- m["pubsub"] || [] do
        entry(member_key(n, m), n["id"], n["label"] || n["id"], s)
      end

    own = for s <- snap["observer_pubsub"] || [], do: entry("observer", "observer", "observer", s)
    nodes ++ own
  end

  defp entry(key, app, label, s),
    do: %{member: key, app: app, label: label, server: s["name"], topics: s["topics"], subs: s["subscriptions"]}

  defp members_of(%{"members" => [_ | _] = ms}), do: Enum.filter(ms, &(&1["ok"] == true))
  defp members_of(inside), do: [inside]

  # as ObsFactor.Wire keys a member: the node name when distributed
  defp member_key(n, m) do
    c = m["cluster"] || %{}
    if c["distributed"] == true and is_binary(c["node"]), do: c["node"], else: n["id"]
  end

  @doc "The tape's PubSub numbers for one snapshot (see the moduledoc)."
  def metrics(snap) do
    for s <- servers(snap), is_binary(s.server), into: %{} do
      {"pubsub:#{s.member}:#{s.server}",
       %{app: s.app, member: s.member, server: s.server, topics: s.topics, subs: s.subs} |> Map.reject(fn {_, v} -> is_nil(v) end)}
    end
  end

  @doc "`{items, state}`: the news of one tick at `now_ms` (see the moduledoc)."
  def news(state, snap, now_ms) do
    now = servers(snap)

    {items, next} =
      Enum.reduce(now, {[], %{}}, fn s, {items, next} ->
        k = {s.member, s.server}
        p = Map.get(state, k, %{samples: [], topics: nil, leak: false})
        samples = sample(p.samples, s.subs, now_ms)
        {leak?, ended?} = leak(samples, s.subs, now_ms)

        leak_item =
          if leak? and not p.leak do
            [{first_at, first} | _] = window(samples, now_ms)

            [item(s, "warn", "#{short(s.server)} subscriptions #{num(first)} → #{num(s.subs)}, never down in #{div(now_ms - first_at, 60_000)} min",
               "a subscription leak on #{short(s.member)}: higher every minute and up in every 10 minutes. A process subscribing again without unsubscribing, or subscribers that never exit")]
          else
            []
          end

        jump_item =
          case {p.topics, s.topics} do
            {a, c} when is_number(a) and is_number(c) and c - a >= @jump_min and c - a >= a * @jump_frac ->
              [item(s, if(c >= a * 3, do: "warn", else: "info"), "#{short(s.server)} topics #{num(a)} → #{num(c)}", "#{pct(a, c)} in one tick on #{short(s.member)}")]

            _ ->
              []
          end

        leak_flag = (p.leak and not ended?) or leak?
        {items ++ leak_item ++ jump_item, Map.put(next, k, %{samples: samples, topics: s.topics, leak: leak_flag})}
      end)

    # a server not seen this tick (a failed read) keeps its samples a while
    kept = for {k, p} <- state, not Map.has_key?(next, k), match?([{at, _} | _] when now_ms - at < @keep_ms, p.samples), into: %{}, do: {k, p}
    {items, Map.merge(kept, next)}
  end

  # One sample a minute; nothing to sample when the walk only counted.
  defp sample(samples, subs, _now_ms) when not is_number(subs), do: samples

  defp sample(samples, subs, now_ms) do
    samples =
      case samples do
        [{at, _} | _] when now_ms - at < @sample_ms -> samples
        _ -> [{now_ms, subs} | samples]
      end

    Enum.filter(samples, fn {at, _} -> now_ms - at <= @keep_ms end)
  end

  # The samples of the last 30 minutes (and the one just before), oldest first.
  defp window(samples, now_ms) do
    {inside, before} = Enum.split_with(samples, fn {at, _} -> now_ms - at < @leak_ms end)
    Enum.reverse(inside ++ Enum.take(before, 1))
  end

  # {leaking now, the run ended (a fall)}
  defp leak(samples, now_subs, now_ms) when is_number(now_subs) do
    xs = window(samples, now_ms) ++ [{now_ms, now_subs}]
    vals = Enum.map(xs, &elem(&1, 1))
    falls = vals |> Enum.chunk_every(2, 1, :discard) |> Enum.any?(fn [a, b] -> b < a end)

    case xs do
      [{t0, v0} | _] when now_ms - t0 >= @leak_ms and not falls ->
        thirds =
          for i <- 1..3 do
            Enum.find(xs, fn {at, _} -> at >= t0 + i * div(@leak_ms, 3) end) |> elem(1)
          end

        steady = Enum.chunk_every([v0 | thirds], 2, 1, :discard) |> Enum.all?(fn [a, b] -> b > a end)
        grew = now_subs - v0
        {steady and grew >= @leak_min and grew >= v0 * @leak_frac, false}

      _ ->
        {false, falls}
    end
  end

  defp leak(_samples, _now_subs, _now_ms), do: {false, false}

  defp item(s, sev, head, text),
    do: %{app: s.app, label: s.label, member: s.member, kind: "pubsub", sev: sev, head: head, text: text}

  defp short(nil), do: "?"
  defp short(name), do: name |> String.trim_leading(":") |> String.replace_prefix("Elixir.", "")

  defp num(n) when is_integer(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp num(n) when is_float(n), do: num(round(n))
  defp num(n), do: inspect(n)

  defp pct(a, c) when a > 0, do: "+#{round((c - a) * 100 / a)}%"
  defp pct(_, _), do: "new"
end
