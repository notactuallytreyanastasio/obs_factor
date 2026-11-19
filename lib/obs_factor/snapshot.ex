defmodule ObsFactor.Snapshot do
  @moduledoc """
  Joins the topology with what the collectors saw into the snapshot of
  docs/contract.md. Pure: `build/4` takes the topology, the sources (as
  `ObsFactor.Sources.all/0` returns them), a small memory carried between
  ticks (when each node was last active) and the time, and returns
  `{snapshot, memory}`.

  Every container Docker lists becomes a node. Containers no topology entry
  claims become `unplaced`; a one-off container (`docker compose run`) never
  stands in for its service and is named by its container name.
  """

  alias ObsFactor.{Format, Rules, Thresholds}

  @resource_ids ["host-cpu", "host-mem", "host-disk"]

  def empty_memory, do: %{last_active: %{}}

  def build(topology, sources, memory, %DateTime{} = now) do
    now_ms = DateTime.to_unix(now, :millisecond)
    host = data(sources.host)
    docker = data(sources.docker)
    caddy = data(sources.caddy)
    pg = data(sources.postgres)
    probes = data(sources.probes)
    sites = data(sources.sites)

    containers = if docker, do: docker.containers, else: []
    {matched, unplaced} = match(topology.nodes, containers)

    env = %{
      now: now,
      now_ms: now_ms,
      host: host,
      docker_ok: docker != nil,
      caddy: caddy,
      pg: pg,
      probes: probes,
      probes_ok: probes != nil,
      sites: sites,
      memory: memory,
      # Resource nodes sit on the "host" platform when the topology has one.
      host_platform: if(Enum.any?(topology.platforms, &(&1.id == "host")), do: "host", else: nil),
      proxy: Enum.find(topology.nodes, &(&1.kind == :proxy))
    }

    listed = Enum.map(topology.nodes, &listed_node(&1, Map.get(matched, &1.id), env))
    extra = Enum.map(unplaced, &unplaced_node(&1, env))

    resources = [
      resource_node("host-cpu", :cpu, env),
      resource_node("host-mem", :mem, env),
      resource_node("host-disk", :disk, env)
    ]

    internet = internet_node(env)
    all = listed ++ resources ++ [internet] ++ extra

    nodes = Enum.map(all, &Map.delete(&1, :attention))

    attention =
      (Enum.map(Rules.sources(sources), fn {sev, text} ->
         %{node: nil, severity: sev, text: text}
       end) ++
         Enum.flat_map(all, fn n ->
           Enum.map(n.attention, fn {sev, text} -> %{node: n.id, severity: sev, text: text} end)
         end))
      |> Rules.order()

    last_active =
      Enum.reduce(all, memory.last_active, fn n, acc ->
        if n[:active_now], do: Map.put(acc, n.id, now_ms), else: acc
      end)

    snapshot = %{
      at: DateTime.to_iso8601(DateTime.truncate(now, :second)),
      tick_ms: Application.get_env(:obs_factor, :tick_ms, 5_000),
      sources: Map.new(sources, fn {k, s} -> {k, %{ok: s.ok, at: iso(s.at), error: s.error}} end),
      host: host_json(host),
      platforms: topology.platforms,
      nodes: Enum.map(nodes, &Map.delete(&1, :active_now)),
      edges: edges(topology, env),
      attention: attention
    }

    {snapshot, %{memory | last_active: last_active}}
  end

  defp data(%{ok: true, data: d}), do: d
  defp data(_), do: nil

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  ## Matching containers to topology entries

  @doc """
  Pairs topology nodes with containers. `service` matches the compose service
  label of a non-one-off container. When several compose projects on the same
  Docker have that service (two stacks both with a `db`), the container from
  the *home project* wins: the project that supplies the most of the
  topology's services. The others become unplaced nodes.
  """
  def match(nodes, containers) do
    home = home_project(nodes, containers)

    {matched, rest} =
      Enum.reduce(nodes, {%{}, containers}, fn node, {acc, pool} ->
        {mine, others} =
          cond do
            node.container -> Enum.split_with(pool, &(&1.name == node.container))
            node.service -> Enum.split_with(pool, &(&1.service == node.service and not &1.oneoff))
            true -> {[], pool}
          end

        {mine, others} =
          case Enum.split_with(mine, &(&1.project == home)) do
            {[], _} -> {mine, others}
            {at_home, elsewhere} -> {at_home, others ++ elsewhere}
          end

        case Enum.sort_by(mine, &{&1.state != "running", &1.name}) do
          [] -> {acc, others}
          # A scaled service: the first running replica is the node, the rest are unplaced.
          [first | replicas] -> {Map.put(acc, node.id, first), others ++ replicas}
        end
      end)

    taken = MapSet.new(Enum.map(nodes, & &1.id) ++ ObsFactor.Topology.reserved_ids())

    {unplaced, _} =
      rest
      |> Enum.sort_by(& &1.name)
      |> Enum.map_reduce(taken, fn c, taken ->
        preferred = if c.oneoff or c.service == nil, do: c.name, else: c.service

        id =
          cond do
            not MapSet.member?(taken, preferred) ->
              preferred

            not MapSet.member?(taken, c.name) ->
              c.name

            true ->
              raise ArgumentError,
                    "container #{c.name} has no free node id (#{preferred} and #{c.name} taken)"
          end

        {{id, c}, MapSet.put(taken, id)}
      end)

    {matched, unplaced}
  end

  defp home_project(nodes, containers) do
    services = for n <- nodes, n.service, into: MapSet.new(), do: n.service

    containers
    |> Enum.filter(&(&1.project && MapSet.member?(services, &1.service) && not &1.oneoff))
    |> Enum.uniq_by(&{&1.project, &1.service})
    |> Enum.frequencies_by(& &1.project)
    |> Enum.sort_by(fn {project, count} -> {-count, project} end)
    |> case do
      [{project, _} | _] -> project
      [] -> nil
    end
  end

  ## Nodes

  defp listed_node(%{kind: kind} = t, container, env) when kind in [:proxy, :app, :relay, :db] do
    hosts = if kind == :proxy, do: proxy_hosts(env), else: host_readings(t.hosts, env)
    pg = if kind == :db, do: env.pg, else: nil
    container_node(t, container, hosts, pg, env)
  end

  defp listed_node(%{kind: :static} = t, _container, env) do
    hosts = host_readings(t.hosts, env)
    site = env.sites && env.sites[t.site]
    active_now = any_traffic?(hosts)
    active = active?(t.id, active_now, env)

    {status, reason, attention} =
      Rules.static_node(%{
        label: t.label,
        sites_ok: env.sites != nil,
        site: site,
        site_name: t.site,
        hosts: hosts,
        active: active
      })

    facts =
      cond do
        site == nil ->
          []

        site[:error] ->
          [fact("size", "unknown"), fact("read error", site.error)]

        true ->
          [
            fact("size", Format.bytes(site.bytes)),
            fact("files", Integer.to_string(site.files)),
            fact("newest file", iso(site.newest_mtime) || "none")
          ]
      end

    %{
      base(t)
      | status: status,
        reason: reason,
        headline: headline_rps(t.hosts, hosts),
        hosts: hosts,
        holds: if(site, do: [%{label: t.site, bytes: site.bytes}], else: []),
        facts: facts ++ host_facts(hosts),
        attention: attention
    }
    |> Map.put(:active_now, active_now)
  end

  defp listed_node(%{kind: :external} = t, _container, _env) do
    %{base(t) | status: "unknown", reason: "not observed", facts: [fact("observed", "no")]}
  end

  defp base(t) do
    %{
      id: t.id,
      label: t.label,
      kind: Atom.to_string(t.kind),
      platform: t.platform,
      pos: t.pos,
      status: "unknown",
      reason: nil,
      headline: %{value: nil, unit: nil},
      container: nil,
      probe: nil,
      hosts: [],
      via: Map.get(t, :via, []),
      holds: [],
      facts: [],
      attention: []
    }
  end

  defp unplaced_node({id, c}, env) do
    t = %{
      id: id,
      label: c.name,
      kind: :unplaced,
      platform: nil,
      pos: nil,
      hosts: [],
      via: [],
      probe: nil,
      databases: [],
      service: c.service,
      container: c.name
    }

    container_node(t, c, [], nil, env)
  end

  defp container_node(t, c, hosts, pg, env) do
    host_total = env.host && env.host.mem_total_bytes
    mem_limit = mem_limit(c, host_total)
    probe = t.probe && env.probes && env.probes[t.id]

    cpu_active =
      c != nil and is_number(c.cpu_cores) and c.cpu_cores >= Thresholds.working_cpu_cores()

    active_now = cpu_active or any_traffic?(hosts) or db_active?(pg)
    active = active?(t.id, active_now, env)

    {status, reason, attention} =
      Rules.container_node(%{
        label: t.label,
        docker_ok: env.docker_ok,
        selector: if(t.service, do: "service #{t.service}", else: "container #{t.container}"),
        container: c,
        mem_limit: mem_limit,
        probe: probe,
        hosts: hosts,
        pg: pg,
        active: active
      })

    # Without Docker, a probe result is still a fact worth showing.
    {status, reason} =
      if (status == "unknown" and not env.docker_ok and probe) && not probe.ok,
        do: {"down", "probe failed: #{probe.error}"},
        else: {status, reason}

    kind = Atom.to_string(t.kind)

    %{
      base(t)
      | kind: kind,
        status: status,
        reason: reason,
        headline: headline(t, c, hosts, pg, env),
        container: container_json(c, mem_limit, env.now),
        probe: probe && Map.take(probe, [:ok, :code, :ms, :error]),
        hosts: hosts,
        holds: if(pg, do: pg_holds(pg), else: []),
        facts: container_facts(c, mem_limit, probe) ++ pg_facts(pg) ++ host_facts(hosts),
        attention: attention
    }
    |> Map.put(:active_now, active_now)
  end

  # Docker reports the host's memory as the limit of an unlimited container;
  # HostConfig.Memory is 0 then (nil after parsing). A limit at or above the
  # host's memory is no limit either.
  defp mem_limit(nil, _), do: nil

  defp mem_limit(%{inspect: %{memory_limit: limit}}, host_total) when is_integer(limit) do
    if is_integer(host_total) and limit >= host_total, do: nil, else: limit
  end

  defp mem_limit(_, _), do: nil

  defp container_json(nil, _, _), do: nil

  defp container_json(c, mem_limit, now) do
    i = c.inspect

    uptime =
      if i && i.running && i.started_at, do: max(DateTime.diff(now, i.started_at), 0), else: nil

    %{
      name: c.name,
      state: c.state,
      status_text: c.status_text,
      uptime_s: uptime,
      restarts: i && i.restart_count,
      oom_killed: i && i.oom_killed,
      cpu_cores: round_to(c.cpu_cores, 4),
      mem_bytes: c.mem_bytes,
      mem_limit_bytes: mem_limit,
      net_rx_bps: round_to(c.net_rx_bps, 1),
      net_tx_bps: round_to(c.net_tx_bps, 1)
    }
  end

  defp container_facts(nil, _, probe), do: probe_facts(probe)

  defp container_facts(c, mem_limit, probe) do
    i = c.inspect

    memory =
      case {c.mem_bytes, mem_limit} do
        {nil, _} -> "unknown"
        {used, nil} -> "#{Format.bytes(used)}, no limit"
        {used, limit} -> "#{Format.bytes(used)} of #{Format.bytes(limit)}"
      end

    [
      fact("state", c.status_text),
      fact("image", c.image),
      fact("service", c.service),
      fact("memory", memory),
      fact("cpu", Format.cores(c.cpu_cores)),
      fact(
        "network",
        "#{Format.rate_bytes(c.net_rx_bps)} in, #{Format.rate_bytes(c.net_tx_bps)} out"
      ),
      i && fact("restarts", Integer.to_string(i.restart_count)),
      i && i.health && fact("health", i.health),
      i && i.oom_killed && fact("oom killed", "yes"),
      i && not i.running && fact("exit code", Integer.to_string(i.exit_code)),
      i && not i.running && i.finished_at && fact("finished", iso(i.finished_at)),
      c.oneoff && fact("one-off", "docker compose run"),
      c.stats_error && fact("stats", c.stats_error),
      c.inspect_error && fact("inspect", c.inspect_error)
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(probe_facts(probe))
  end

  defp probe_facts(nil), do: []
  defp probe_facts(%{ok: true, code: code, ms: ms}), do: [fact("probe", "#{code} in #{ms} ms")]
  defp probe_facts(%{error: e}), do: [fact("probe", "failed: #{e}")]

  defp pg_holds(pg) do
    pg.databases
    |> Enum.sort_by(fn {name, d} -> {-(d.bytes || 0), name} end)
    |> Enum.map(fn {name, d} -> %{label: name, bytes: d.bytes} end)
  end

  defp pg_facts(nil), do: []

  defp pg_facts(pg) do
    [fact("connections", "#{pg.connections} of #{pg.max_connections}")] ++
      Enum.map(Enum.sort(pg.databases), fn {name, d} ->
        fact(
          name,
          "#{Format.bytes(d.bytes)}, #{d.connections} conns, #{commits(d.commits_per_s)}"
        )
      end)
  end

  defp commits(nil), do: "commits/s unknown"
  defp commits(r), do: "#{:erlang.float_to_binary(r / 1, decimals: 1)} commits/s"

  defp host_facts(hosts) do
    for h <- hosts do
      lat =
        if h.avg_ms, do: ", #{:erlang.float_to_binary(h.avg_ms / 1, decimals: 1)} ms", else: ""

      fact(h.host, Format.rps(h.rps) <> lat)
    end
  end

  defp fact(_label, nil), do: nil
  defp fact(label, value), do: %{label: label, value: value}

  ## Headlines

  defp headline(%{kind: :proxy}, _c, _hosts, _pg, env),
    do: %{value: round_to(env.caddy && env.caddy.total_rps, 2), unit: "req/s"}

  defp headline(%{kind: :db}, _c, _hosts, pg, _env),
    do: %{
      value: round_to(pg && sum(Enum.map(pg.databases, fn {_, d} -> d.commits_per_s end)), 2),
      unit: "commits/s"
    }

  defp headline(%{hosts: [_ | _] = names}, _c, hosts, _pg, _env), do: headline_rps(names, hosts)

  defp headline(%{kind: :relay}, c, _hosts, _pg, _env) do
    value = c && sum([c.net_rx_bps, c.net_tx_bps])
    %{value: round_to(value, 1), unit: "B/s"}
  end

  defp headline(_t, c, _hosts, _pg, _env),
    do: %{value: round_to(c && c.cpu_cores, 4), unit: "cores"}

  defp headline_rps([], _), do: %{value: nil, unit: nil}

  defp headline_rps(_, hosts),
    do: %{value: round_to(sum(Enum.map(hosts, & &1.rps)), 2), unit: "req/s"}

  # nil if any part is unknown: a sum with a hole in it is not the total.
  defp sum([]), do: 0.0
  defp sum(values), do: if(Enum.any?(values, &is_nil/1), do: nil, else: Enum.sum(values) / 1)

  ## Hosts (Caddy)

  defp host_readings(names, env) do
    Enum.map(names, fn h ->
      case env.caddy do
        nil ->
          %{host: h, rps: nil, err_rps: nil, avg_ms: nil}

        caddy ->
          case caddy.hosts[h] do
            nil when caddy.total_rps != nil ->
              # Caddy is read and has never seen a request for this host.
              %{host: h, rps: 0.0, err_rps: 0.0, avg_ms: nil}

            nil ->
              %{host: h, rps: nil, err_rps: nil, avg_ms: nil}

            r ->
              %{
                host: h,
                rps: round_to(r.rps, 3),
                err_rps: round_to(r.err_rps, 3),
                avg_ms: round_to(r.avg_ms, 1)
              }
          end
      end
    end)
  end

  defp proxy_hosts(%{caddy: nil}), do: []

  defp proxy_hosts(%{caddy: caddy} = env) do
    caddy.hosts
    |> Map.keys()
    |> host_readings(env)
    |> Enum.sort_by(&{-(&1.rps || 0), &1.host})
  end

  defp any_traffic?(hosts), do: Enum.any?(hosts, &(is_number(&1.rps) and &1.rps > 0))

  defp db_active?(nil), do: false

  defp db_active?(pg),
    do:
      Enum.any?(pg.databases, fn {_, d} -> is_number(d.commits_per_s) and d.commits_per_s > 0 end)

  defp active?(id, active_now, env) do
    active_now or
      case env.memory.last_active[id] do
        nil -> false
        t -> env.now_ms - t <= Thresholds.working_window_ms()
      end
  end

  ## Resource and source nodes

  defp resource_node(id, which, env) do
    host = env.host
    {status, reason, attention} = Rules.resource_node(which, host)

    {label, headline, holds, facts} =
      case {which, host} do
        {:cpu, nil} ->
          {"CPU", %{value: nil, unit: "cores"}, [], []}

        {:cpu, h} ->
          {"CPU", %{value: round_to(h.cpu_used_cores, 3), unit: "cores"}, [],
           [
             fact("cores", Integer.to_string(h.cores)),
             fact("used", Format.cores(h.cpu_used_cores)),
             fact("load (1 min)", "#{h.load1}")
           ]}

        {:mem, nil} ->
          {"Memory", %{value: nil, unit: "B"}, [], []}

        {:mem, h} ->
          {"Memory", %{value: h.mem_used_bytes, unit: "B"}, [],
           [
             fact(
               "used",
               "#{Format.bytes(h.mem_used_bytes)} of #{Format.bytes(h.mem_total_bytes)}"
             )
           ]}

        {:disk, nil} ->
          {"Disk", %{value: nil, unit: "%"}, [], []}

        {:disk, h} ->
          frac = Rules.disk_fraction(h)

          {"Disk", %{value: Float.round(frac * 100, 1), unit: "%"},
           [
             %{label: "used", bytes: h.disk_used_bytes},
             %{label: "free", bytes: h.disk_avail_bytes}
           ],
           [
             fact(
               "used",
               "#{Format.bytes(h.disk_used_bytes)} of #{Format.bytes(h.disk_total_bytes)} (#{Format.percent(frac)})"
             ),
             fact("available", Format.bytes(h.disk_avail_bytes))
           ]}
      end

    %{
      base(%{
        id: id,
        label: label,
        kind: :resource,
        platform: env.host_platform,
        pos: nil,
        via: []
      })
      | status: status,
        reason: reason,
        headline: headline,
        holds: holds,
        facts: facts,
        attention: attention
    }
  end

  defp internet_node(env) do
    total = env.caddy && env.caddy.total_rps

    {status, reason} =
      cond do
        env.caddy == nil -> {"unknown", "caddy source failing"}
        active?("internet", is_number(total) and total > 0, env) -> {"working", nil}
        true -> {"idle", nil}
      end

    %{
      base(%{id: "internet", label: "Internet", kind: :source, platform: nil, pos: nil, via: []})
      | status: status,
        reason: reason,
        headline: %{value: round_to(total, 2), unit: "req/s"},
        facts: [fact("requests", Format.rps(total))]
    }
    |> Map.put(:active_now, is_number(total) and total > 0)
  end

  ## Edges

  defp edges(topology, env) do
    proxy = env.proxy
    db = Enum.find(topology.nodes, &(&1.kind == :db))

    internet =
      if proxy do
        [
          edge(
            "internet",
            proxy.id,
            "requests",
            round_to(env.caddy && env.caddy.total_rps, 2),
            "req/s",
            true,
            "all hosts"
          )
        ]
      else
        []
      end

    to_nodes =
      if proxy do
        for n <- topology.nodes, n.hosts != [] or n.via != [] do
          if n.hosts != [] do
            rate = sum(Enum.map(host_readings(n.hosts, env), & &1.rps))

            edge(
              proxy.id,
              n.id,
              "requests",
              round_to(rate, 2),
              "req/s",
              true,
              Enum.join(n.hosts, ", ")
            )
          else
            edge(proxy.id, n.id, "requests", nil, "req/s", false, Enum.join(n.via, ", "))
          end
        end
      else
        []
      end

    to_db =
      if db do
        for n <- topology.nodes, n.databases != [] do
          rate =
            case env.pg do
              nil ->
                nil

              pg ->
                sum(Enum.map(n.databases, &(pg.databases[&1] && pg.databases[&1].commits_per_s)))
            end

          edge(
            n.id,
            db.id,
            "commits",
            round_to(rate, 2),
            "commits/s",
            true,
            Enum.join(n.databases, ", ")
          )
        end
      else
        []
      end

    extra = for e <- topology.edges, do: edge(e.from, e.to, e.item, nil, nil, false, e.item)
    internet ++ to_nodes ++ to_db ++ extra
  end

  defp edge(from, to, item, rate, unit, metered, label) do
    %{
      id: "#{from}>#{to}",
      from: from,
      to: to,
      item: item,
      rate: rate,
      unit: unit,
      metered: metered,
      label: label
    }
  end

  ## Host summary

  defp host_json(nil) do
    %{
      cores: nil,
      cpu_used_cores: nil,
      load1: nil,
      mem_used_bytes: nil,
      mem_total_bytes: nil,
      disk_used_bytes: nil,
      disk_total_bytes: nil,
      disk_avail_bytes: nil
    }
  end

  defp host_json(h) do
    %{
      cores: h.cores,
      cpu_used_cores: round_to(h.cpu_used_cores, 3),
      load1: h.load1,
      mem_used_bytes: h.mem_used_bytes,
      mem_total_bytes: h.mem_total_bytes,
      disk_used_bytes: h.disk_used_bytes,
      disk_total_bytes: h.disk_total_bytes,
      disk_avail_bytes: h.disk_avail_bytes
    }
  end

  defp round_to(nil, _), do: nil
  defp round_to(v, digits) when is_float(v), do: Float.round(v, digits)
  defp round_to(v, _digits) when is_integer(v), do: v / 1

  @doc false
  def resource_ids, do: @resource_ids
end
