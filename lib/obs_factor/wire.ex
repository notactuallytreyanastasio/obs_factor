defmodule ObsFactor.Wire do
  @moduledoc """
  The BEAM wire: what happened inside the live Erlang systems on the floor,
  tick by tick, as news. The board's chyron, crawl and Wire feed read it;
  nothing else on the box (static sites, external services, the host)
  is news here.

  Each tick, `observe/4` compares the snapshot with the last one and says
  what changed:

    * inside each BEAM member (every node of a cluster): it restarted
      (uptime went down), it joined or left, its process count jumped,
      the run queue outgrew the schedulers, scheduler utilisation crossed
      75 %, total or binary memory jumped, atoms grew (a leak never comes
      back down), the report's handler crashed;
    * between members: a connection to a peer went (a partition) or came,
      a send queue backed up, a `:global` name moved, which is a new leader
      for something meant to be one in the cluster;
    * what each app reported: a logged error or warning (with where it
      came from), a stream failing (`err_rate` above 0), Repo queries
      surging or slowing, LiveView mounts surging;
    * mailboxes: a process holding 100 or more messages (read by
      `ObsFactor.Wire.Mailboxes` from the observer engine);
    * Postgres, per app database (the topology's `databases:`): connections
      jumping, commits surging, the server's connections near its limit.

  The first tick only learns: nothing that was already true when the
  observer started is news. The same kind of item about the same member is
  not repeated within a minute.

  An item: `%{at, app, label, member, kind, sev, head, text}`, `sev` one of
  `"alert" | "warn" | "info"`. The snapshot is read as JSON (string keys),
  the same document the browser gets.
  """

  @quiet_ms 60_000

  def new, do: %{first: true, members: %{}, events: MapSet.new(), streams: %{}, db: %{}, total_conns: nil, mbox: %{}, said: %{}}

  @doc "`{items, state}` for one snapshot (decoded JSON) at `now_ms`."
  def observe(state, snap, now_ms, mailboxes \\ %{}) do
    nodes = snap["nodes"] || []
    beams = beams(nodes)
    dbs = databases(nodes)

    items =
      if state.first,
        do: [],
        else:
          member_news(state, beams) ++
            app_news(state, nodes) ++ db_news(state, dbs, nodes) ++ mailbox_news(state, beams, mailboxes)

    {items, said} = quiet(items, state.said, now_ms)

    state = %{
      state
      | first: false,
        members: remember(state.members, beams),
        events: seen_events(nodes, state.events),
        streams: streams(nodes),
        db: dbs.per_db,
        total_conns: dbs.total,
        mbox: top_boxes(beams, mailboxes),
        said: said
    }

    {Enum.map(items, &Map.put(&1, :at, now_ms)), state}
  end

  @doc """
  The tape's BEAM numbers for one snapshot: per member (`"beam:" <> node`)
  and per app database (`"pg:" <> db`), so the board can chart and replay
  them. Mailboxes: the biggest message queue the observer engine read.
  """
  def metrics(snap, mailboxes \\ %{}) do
    nodes = snap["nodes"] || []
    beams = beams(nodes)

    members =
      for b <- beams, into: %{} do
        g = b.gauges
        r = b.rates
        box = top_box(mailboxes, b)

        {"beam:" <> b.key,
         %{
           app: b.app,
           procs: g["process.count"],
           rq: g["run_queue"],
           sched: g["schedulers.online"],
           util: g["scheduler.utilization"],
           mem: g["memory.total"],
           bin: g["memory.binary"],
           ets_mem: g["memory.ets"],
           atoms: g["atom.count"],
           reds: r["reductions"],
           gc: r["gc.count"],
           dist_out: b.conns |> Map.values() |> Enum.map(&(&1["out_bps"] || 0)) |> Enum.sum(),
           sendq: b.conns |> Map.values() |> Enum.map(&(&1["send_queue_bytes"] || 0)) |> Enum.max(fn -> 0 end),
           peers: map_size(b.conns),
           mbox: box && box.len,
           mbox_name: box && box.name,
           up: b.uptime,
           leads: b.leads
         }
         |> Map.reject(fn {_, v} -> is_nil(v) end)}
      end

    queries =
      for n <- nodes, beam?(n), s <- n["inside"]["streams"] || [], s["kind"] == "db.query", into: %{} do
        {"repo:" <> n["id"], %{app: n["id"], rate: s["rate"], ms: s["avg_ms"], err: s["err_rate"], name: s["name"]}}
      end

    dbs =
      for {db, d} <- databases(nodes).per_db, into: %{} do
        {"pg:" <> db, %{app: d.app, conns: d.conns, commits: d.commits}}
      end

    members |> Map.merge(queries) |> Map.merge(dbs)
  end

  # ---- reading the snapshot ------------------------------------------------

  defp beam?(n), do: match?(%{"inside" => %{"ok" => true, "runtime" => %{"kind" => "beam"}}}, n)

  # every member of every BEAM app; a single node is its own member
  defp beams(nodes) do
    for n <- nodes, beam?(n), m <- members_of(n["inside"]) do
      cluster = m["cluster"] || %{}
      key = cluster["node"] || n["id"]
      rt = m["runtime"] || %{}

      %{
        key: key,
        app: n["id"],
        label: n["label"],
        address: m["address"],
        gauges: rt["gauges"] || %{},
        rates: rt["rates"] || %{},
        uptime: rt["uptime_s"],
        conns: Map.new(cluster["connections"] || [], &{&1["node"], &1}),
        globals: Map.new(cluster["globals"] || [], &{&1["name"], &1["node"]}),
        leads: for(%{"name" => name, "node" => ^key} <- cluster["globals"] || [], do: name)
      }
    end
  end

  defp members_of(%{"members" => [_ | _] = ms}), do: Enum.filter(ms, &(&1["ok"] == true))
  defp members_of(inside), do: [inside]

  defp streams(nodes) do
    for n <- nodes, beam?(n), s <- n["inside"]["streams"] || [], into: %{} do
      {{n["id"], s["kind"], s["name"]}, s}
    end
  end

  defp seen_events(nodes, seen) do
    keys = for n <- nodes, beam?(n), e <- n["inside"]["events"] || [], do: event_key(n, e)
    # only what reports still carry is remembered: they keep their last few
    if keys == [], do: seen, else: MapSet.new(keys)
  end

  defp event_key(n, e), do: {n["id"], e["at"], e["name"], String.slice(e["message"] || "", 0, 120)}

  # "blog_prod" => "2.5 GB, 19 conns, 2.0 commits/s", and "connections" => "85 of 100"
  defp databases(nodes) do
    owner = for n <- ObsFactor.topology().nodes, db <- Map.get(n, :databases) || [], into: %{}, do: {db, n.id}

    case Enum.find(nodes, &(&1["kind"] == "db")) do
      nil ->
        %{per_db: %{}, total: nil}

      db ->
        facts = db["facts"] || []

        per_db =
          for %{"label" => label, "value" => v} <- facts,
              Map.has_key?(owner, label),
              [_, c, k] <- [Regex.run(~r/(\d+) conns, ([\d.]+) commits\/s/, v || "")],
              into: %{} do
            {label, %{app: owner[label], conns: String.to_integer(c), commits: String.to_float(ensure_dot(k))}}
          end

        total =
          Enum.find_value(facts, fn
            %{"label" => "connections", "value" => v} ->
              case Regex.run(~r/(\d+) of (\d+)/, v || "") do
                [_, a, b] -> {String.to_integer(a), String.to_integer(b)}
                _ -> nil
              end

            _ ->
              nil
          end)

        %{per_db: per_db, total: total}
    end
  rescue
    # the topology is not loaded in some tests: no database news, not a crash
    _ in [ArgumentError, KeyError] -> %{per_db: %{}, total: nil}
  end

  defp ensure_dot(s), do: if(String.contains?(s, "."), do: s, else: s <> ".0")

  defp top_box(mailboxes, b) do
    case Map.get(mailboxes, {b.app, b.address}) || Map.get(mailboxes, {b.app, nil}) do
      %{top: [p | _]} -> %{len: p["message_queue_len"] || 0, name: proc_name(p)}
      _ -> nil
    end
  end

  defp top_boxes(beams, mailboxes), do: Map.new(beams, &{&1.key, top_box(mailboxes, &1)})

  defp proc_name(p), do: p["registered_name"] || p["initial_call"] || p["pid"]

  # An app whose report could not be read this tick (it is restarting, as
  # often as not) keeps its members as last seen: when it answers again its
  # uptime is compared with that, and the restart is news. Forgetting them
  # made a restarted node look like a new one, and said nothing.
  defp remember(prev, beams) do
    apps = MapSet.new(beams, & &1.app)
    kept = for {k, m} <- prev, not MapSet.member?(apps, m.app), into: %{}, do: {k, m}
    Map.merge(kept, Map.new(beams, &{&1.key, &1}))
  end

  # ---- what changed ----------------------------------------------------------

  defp member_news(state, beams) do
    now = Map.new(beams, &{&1.key, &1})
    prev = state.members
    apps_now = beams |> Enum.group_by(& &1.app)

    joined_left =
      for {key, b} <- now, not Map.has_key?(prev, key), Enum.any?(prev, fn {_, p} -> p.app == b.app end) do
        item(b, "joined", "info", "#{short(key)} joined", "#{b.label} now runs on #{length(apps_now[b.app])} nodes")
      end ++
        for {key, p} <- prev, not Map.has_key?(now, key), Map.has_key?(apps_now, p.app) do
          item(p, "left", "warn", "#{short(key)} left", "#{p.label} is down to #{length(apps_now[p.app])} nodes")
        end

    (joined_left ++
       Enum.flat_map(now, fn {key, b} ->
         case prev[key] do
           nil -> []
           p -> member_changes(p, b)
         end
       end))
    # every member sees a global move: it is one piece of news
    |> Enum.uniq_by(fn i -> if i.kind == "leader", do: {:leader, i.head}, else: make_ref() end)
  end

  defp member_changes(p, b) do
    g0 = p.gauges
    g = b.gauges

    restart =
      if is_number(b.uptime) and is_number(p.uptime) and b.uptime < p.uptime,
        do: [item(b, "restart", "warn", "#{short(b.key)} restarted", "up #{dur(p.uptime)} before; #{num(g["process.count"])} processes now")],
        else: []

    procs =
      case {g0["process.count"], g["process.count"]} do
        {a, c} when is_number(a) and is_number(c) and abs(c - a) >= 200 and abs(c - a) >= a * 0.2 ->
          [item(b, "procs", if(c > a, do: "warn", else: "info"), "processes #{num(a)} → #{num(c)}", "#{pct(a, c)} in one tick on #{short(b.key)}")]

        _ ->
          []
      end

    sched = g["schedulers.online"] || 1

    rq =
      if crossed(g0["run_queue"], g["run_queue"], sched),
        do: [item(b, "runq", "warn", "run queue #{g["run_queue"]} on #{sched} schedulers", "more runnable processes than schedulers: #{short(b.key)} is CPU-bound")],
        else: []

    util =
      if crossed(g0["scheduler.utilization"], g["scheduler.utilization"], 0.75),
        do: [item(b, "util", "warn", "schedulers #{round(g["scheduler.utilization"] * 100)}% busy", "#{short(b.key)}")],
        else: []

    mem =
      jump(b, "memory", "memory.total", g0, g, 0.3, 50_000_000, "total memory") ++
        jump(b, "binary", "memory.binary", g0, g, 0.5, 50_000_000, "binary heap (refc binaries)")

    atoms =
      case {g0["atom.count"], g["atom.count"], g["atom.limit"]} do
        {a, c, lim} when is_number(a) and is_number(c) and c - a >= 500 ->
          [item(b, "atoms", if(is_number(lim) and c > lim * 0.8, do: "alert", else: "warn"), "atoms +#{num(c - a)}",
             "#{num(c)} of #{num(lim)}: atoms are never collected, a steady climb is a leak")]

        _ ->
          []
      end

    handler =
      if (b.rates["report.handler_errors"] || 0) > 0 and (p.rates["report.handler_errors"] || 0) == 0,
        do: [item(b, "handler", "warn", "telemetry handler crashing", "#{b.rates["report.handler_errors"]}/s handler errors in the report on #{short(b.key)}")],
        else: []

    peers =
      for {peer, _} <- p.conns, not Map.has_key?(b.conns, peer),
          do: item(b, "partition", "alert", "#{short(b.key)} lost #{short(peer)}", "the distribution connection between them went")

    peers =
      peers ++
        for {peer, _} <- b.conns, not Map.has_key?(p.conns, peer), map_size(p.conns) > 0,
            do: item(b, "connected", "info", "#{short(b.key)} ⇄ #{short(peer)}", "distribution connection up")

    sendq =
      for {peer, c} <- b.conns,
          q = c["send_queue_bytes"] || 0,
          q >= 65_536,
          ((p.conns[peer] || %{})["send_queue_bytes"] || 0) < 65_536,
          do: item(b, "sendq", "warn", "send queue to #{short(peer)} #{bytes(q)}", "messages to #{peer} are backing up on #{short(b.key)}")

    leaders =
      for {name, home} <- b.globals, old = p.globals[name], old != nil, old != home,
          do: item(b, "leader", "warn", "#{short_name(name)} moved #{short(old)} → #{short(home)}", "#{name}: a new leader in the cluster")

    restart ++ procs ++ rq ++ util ++ mem ++ atoms ++ handler ++ peers ++ sendq ++ Enum.uniq_by(leaders, & &1.head)
  end

  defp jump(b, kind, key, g0, g, frac, min, what) do
    case {g0[key], g[key]} do
      {a, c} when is_number(a) and is_number(c) and c - a >= min and c - a >= a * frac ->
        [item(b, kind, "warn", "#{what} #{bytes(a)} → #{bytes(c)}", "#{pct(a, c)} in one tick on #{short(b.key)}")]

      _ ->
        []
    end
  end

  defp crossed(a, c, line), do: is_number(c) and c > line and not (is_number(a) and a > line)

  defp app_news(state, nodes) do
    for n <- nodes, beam?(n), reduce: [] do
      acc ->
        inside = n["inside"]
        app = %{app: n["id"], label: n["label"], key: nil}

        events =
          for e <- inside["events"] || [],
              not MapSet.member?(state.events, event_key(n, e)),
              e["level"] in ["error", "warning", "critical", "alert", "emergency"] do
            where = case e["by"] do
              %{"name" => name} -> " at #{name}"
              _ -> ""
            end

            first = (e["message"] || "") |> String.split("\n", trim: true) |> Enum.take(2) |> Enum.join(" ")
            sev = if e["level"] == "warning", do: "warn", else: "alert"
            item(app, if(sev == "alert", do: "error", else: "warning"), sev, "#{e["level"]} in #{e["name"]}#{where}", String.slice(first, 0, 240))
          end

        streams =
          for s <- inside["streams"] || [] do
            p = state.streams[{n["id"], s["kind"], s["name"]}] || %{}
            stream_news(app, s, p)
          end
          |> List.flatten()

        acc ++ events ++ streams
    end
  end

  defp stream_news(app, s, p) do
    rate = s["rate"] || 0
    rate0 = p["rate"] || 0
    err = s["err_rate"] || 0
    label = "#{s["name"]}"

    failing =
      if err > 0 and (p["err_rate"] || 0) == 0 and s["kind"] != "log",
        do: [item(app, "failing", "alert", "#{s["kind"]} #{short_name(label)} failing #{round(err * 100)}%", "#{num(rate)}/s, #{round(err * 100)}% of them errors")],
        else: []

    surge =
      if s["kind"] in ["db.query", "liveview.mount", "http.route", "oban.job"] and rate >= 1 and rate >= rate0 * 3 and p != %{},
        do: [item(app, "surge", "info", "#{kind_word(s["kind"])} #{num(rate0)} → #{num(rate)}/s", label)],
        else: []

    slow =
      if s["kind"] == "db.query" and crossed(p["avg_ms"], s["avg_ms"], 200),
        do: [item(app, "slowq", "warn", "Repo queries #{num(s["avg_ms"])} ms on average", label)],
        else: []

    failing ++ surge ++ slow
  end

  defp kind_word("db.query"), do: "Repo queries"
  defp kind_word("liveview.mount"), do: "LiveView mounts"
  defp kind_word("http.route"), do: "requests"
  defp kind_word("oban.job"), do: "jobs"
  defp kind_word(k), do: k

  defp db_news(state, dbs, nodes) do
    labels = Map.new(nodes, &{&1["id"], &1["label"]})

    per =
      for {db, d} <- dbs.per_db, p = state.db[db], p != nil, reduce: [] do
        acc ->
          who = %{app: d.app, label: labels[d.app] || d.app, key: nil}

          conns =
            if d.conns - p.conns >= 5,
              do: [item(who, "dbconns", "info", "#{db} connections #{p.conns} → #{d.conns}", "the pool grew: more checkouts at once")],
              else: []

          commits =
            if d.commits >= 5 and d.commits >= p.commits * 3,
              do: [item(who, "commits", "info", "#{db} commits #{num(p.commits)} → #{num(d.commits)}/s", "a write burst")],
              else: []

          acc ++ conns ++ commits
      end

    total =
      case {state.total_conns, dbs.total} do
        {old, {a, max}} when a >= max * 0.9 ->
          if match?({o, _} when o >= max * 0.9, old),
            do: [],
            else: [item(%{app: "db", label: "Postgres", key: nil}, "pgfull", "alert", "Postgres #{a} of #{max} connections", "new connections are refused at the limit, for every app on the box")]

        _ ->
          []
      end

    per ++ total
  end

  defp mailbox_news(state, beams, mailboxes) do
    for b <- beams, box = top_box(mailboxes, b), box != nil, box.len >= 100 do
      old = state.mbox[b.key]

      if old != nil and old.len >= 100 and old.name == box.name,
        do: nil,
        else:
          item(b, "mailbox", if(box.len >= 10_000, do: "alert", else: "warn"), "#{short_name(box.name)} holds #{num(box.len)} messages",
            "the biggest mailbox on #{short(b.key)}: a process receiving faster than it handles")
    end
    |> Enum.reject(&is_nil/1)
  end

  # ---- items ------------------------------------------------------------------

  defp item(who, kind, sev, head, text),
    do: %{app: who.app, label: who.label, member: who.key, kind: kind, sev: sev, head: head, text: text}

  # one kind of item about one member at most once a minute
  defp quiet(items, said, now) do
    said = Map.reject(said, fn {_, at} -> now - at > @quiet_ms end)

    Enum.reduce(items, {[], said}, fn i, {out, said} ->
      k = {i.app, i.member, i.kind, if(i.kind in ~w(error warning failing leader partition connected), do: i.head)}
      if Map.has_key?(said, k), do: {out, said}, else: {[i | out], Map.put(said, k, now)}
    end)
    |> then(fn {out, said} -> {Enum.reverse(out), said} end)
  end

  # "marginalia@172.18.0.12" -> "marginalia@.0.12": the last two octets
  # are what tells the members of one compose network apart
  defp short(nil), do: "?"

  defp short(node) when is_binary(node) do
    case String.split(node, "@") do
      [name, host] ->
        case String.split(host, ".") do
          [_, _, c, d] -> "#{name}@.#{c}.#{d}"
          _ -> node
        end

      _ ->
        node
    end
  end

  defp short_name(name) when is_binary(name), do: name |> String.trim_leading(":") |> String.replace_prefix("Elixir.", "")
  defp short_name(other), do: inspect(other)

  defp num(n) when is_integer(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp num(n) when is_float(n) and n >= 100, do: num(round(n))
  defp num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: if(n >= 10, do: 1, else: 2)) |> String.replace(~r/\.?0+$/, "")
  defp num(n), do: inspect(n)

  defp pct(a, c) when a > 0, do: "#{if c >= a, do: "+", else: ""}#{round((c - a) * 100 / a)}%"
  defp pct(_, _), do: "new"

  defp bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 1)} GB"
  defp bytes(b) when b >= 1_048_576, do: "#{round(b / 1_048_576)} MB"
  defp bytes(b) when b >= 1024, do: "#{round(b / 1024)} KB"
  defp bytes(b), do: "#{b} B"

  defp dur(s) when s >= 86_400, do: "#{div(s, 86_400)}d #{div(rem(s, 86_400), 3600)}h"
  defp dur(s) when s >= 3600, do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
  defp dur(s), do: "#{div(s, 60)}m"
end
