defmodule ObsFactor.Rules do
  @moduledoc """
  Status and attention rules. Each function takes what is known about one node
  and returns `{status, reason, attention}` where attention is a list of
  `{severity, text}`. Thresholds come from `ObsFactor.Thresholds`.

  Order of precedence for a container node, first match wins for the status:

    1. docker source failing             -> unknown
    2. listed but no container           -> down    (alert)
    3. inspect failed                    -> unknown (warn)
    4. restarting / restart loop         -> down    (alert)
    5. not running, one-shot exited 0    -> idle
       not running otherwise             -> down    (alert)
    6. probe failing                     -> down    (alert)
    7. unhealthy, memory near limit, 5xx,
       Postgres connections near max     -> blocked (alert or warn)
    8. activity in the last minute       -> working, else idle

  Warnings that do not change the status: a recent restart, a past OOM kill,
  a failed stats call, a failing report.
  """

  alias ObsFactor.Format
  alias ObsFactor.Thresholds, as: T

  @doc """
  `ctx` keys: `:label`, `:docker_ok`, `:listed` (has a topology entry),
  `:selector` (what it was looked up by), `:container` (merged Docker data or
  nil), `:mem_limit`, `:probe`, `:hosts`, `:pg` (Postgres data for the db
  node), `:active`.
  """
  def container_node(ctx) do
    c = ctx.container
    label = ctx.label

    cond do
      not ctx.docker_ok ->
        {"unknown", "docker source failing", []}

      c == nil ->
        {"down", "no container", [{"alert", "#{label}: no container for #{ctx.selector}"}]}

      c.inspect == nil ->
        {"unknown", "inspect failed: #{c.inspect_error}",
         [{"warn", "#{label}: inspect failed: #{c.inspect_error}"}]}

      c.inspect.restarting or c.restarts_recent >= T.restart_loop_count() ->
        reason =
          case c.restarts_recent do
            # Docker says restarting but we have not seen the count rise (yet,
            # or it was reset by `docker restart`): no number we cannot back.
            0 -> "restarting"
            n -> "restart loop (#{n} restarts in #{T.restart_window_label()})"
          end

        {"down", reason, [{"alert", "#{label}: #{reason}"}]}

      not c.inspect.running ->
        not_running(ctx)

      ctx.probe != nil and not ctx.probe.ok ->
        reason = "probe failed: #{ctx.probe.error}"
        # Down wins the status, but what would have blocked it is still news.
        also = Enum.map(blocking(ctx), fn {sev, _, text} -> {sev, text} end)
        {"down", reason, [{"alert", "#{label}: #{reason}"} | also] ++ side_warnings(ctx)}

      true ->
        running(ctx)
    end
  end

  defp not_running(ctx) do
    i = ctx.container.inspect
    label = ctx.label

    cond do
      i.exit_code == 0 and one_shot?(ctx.container) ->
        {"idle", nil, []}

      i.oom_killed ->
        {"down", "OOM killed", [{"alert", "#{label}: OOM killed"}]}

      i.status == "exited" ->
        reason = "exited (code #{i.exit_code})"
        {"down", reason, [{"alert", "#{label}: #{reason}"}]}

      true ->
        reason = "#{i.status}"
        {"down", reason, [{"alert", "#{label}: #{reason}"}]}
    end
  end

  @doc """
  A one-shot container: started by `docker compose run` (the oneoff label),
  or one Docker is not told to restart. Exiting 0 is how it finishes.
  """
  def one_shot?(container) do
    container.oneoff or container.inspect.restart_policy in ["no", "on-failure", "", nil]
  end

  defp running(ctx) do
    blocks = blocking(ctx)
    warnings = side_warnings(ctx)

    case blocks do
      [{_sev, reason, _text} | _] ->
        {"blocked", reason, Enum.map(blocks, fn {sev, _, text} -> {sev, text} end) ++ warnings}

      [] ->
        {if(ctx.active, do: "working", else: "idle"), nil, warnings}
    end
  end

  # {severity, reason, attention text} for every reason the node is blocked.
  defp blocking(ctx) do
    c = ctx.container
    label = ctx.label

    unhealthy =
      if c.inspect.health == "unhealthy",
        do: [{"alert", "healthcheck unhealthy", "#{label}: healthcheck unhealthy"}],
        else: []

    memory =
      case {c.mem_bytes, ctx.mem_limit} do
        {used, limit} when is_integer(used) and is_integer(limit) ->
          frac = used / limit

          if frac >= T.memory_near_limit() do
            reason = "memory at #{Format.percent(frac)} of limit"

            [
              {"warn", reason,
               "#{label}: memory #{Format.bytes(used)} of #{Format.bytes(limit)} limit"}
            ]
          else
            []
          end

        _ ->
          []
      end

    errors(ctx.hosts, label) ++ unhealthy ++ memory ++ pg_connections(ctx[:pg], label)
  end

  @doc "5xx rules for a list of host readings."
  def errors(hosts, label) do
    for %{host: h, err_rps: e} <- hosts || [], is_number(e) and e > 0 do
      sev = if e >= T.errors_alert_rps(), do: "alert", else: "warn"
      rate = :erlang.float_to_binary(e / 1, decimals: 2)
      {sev, "5xx at #{rate}/s on #{h}", "#{label}: #{h} answering 5xx at #{rate}/s"}
    end
  end

  defp pg_connections(%{connections: used, max_connections: max}, _label)
       when is_integer(used) and is_integer(max) and max > 0 do
    if used / max > T.pg_connections_alert() do
      [{"alert", "#{used} of #{max} connections", "Postgres at #{used} of #{max} connections"}]
    else
      []
    end
  end

  defp pg_connections(_, _), do: []

  defp side_warnings(ctx) do
    c = ctx.container
    label = ctx.label

    restarted =
      if c.restarts_recent > 0,
        do: [{"warn", "#{label}: restarted #{c.restarts_recent}x in #{T.restart_window_label()}"}],
        else: []

    oom =
      if c.inspect.oom_killed,
        do: [{"warn", "#{label}: was OOM killed before its current start"}],
        else: []

    stats = if c.stats_error, do: [{"warn", "#{label}: #{c.stats_error}"}], else: []
    restarted ++ oom ++ stats
  end

  @doc "A static site node."
  def static_node(ctx) do
    cond do
      not ctx.sites_ok ->
        {"unknown", "sites source failing", []}

      ctx.site == nil ->
        reason = "no directory #{ctx.site_name} in SITES_DIR"
        {"down", reason, [{"alert", "#{ctx.label}: #{reason}"}]}

      ctx.site[:error] ->
        {"unknown", "site directory unreadable", [{"warn", "#{ctx.label}: #{ctx.site.error}"}]}

      true ->
        case errors(ctx.hosts, ctx.label) do
          [{_, reason, _} | _] = errs ->
            {"blocked", reason, Enum.map(errs, fn {s, _, t} -> {s, t} end)}

          [] ->
            {if(ctx.active, do: "working", else: "idle"), nil, []}
        end
    end
  end

  @doc "A host resource node: `:cpu`, `:mem` or `:disk`."
  def resource_node(_which, nil), do: {"unknown", "host source failing", []}

  def resource_node(:cpu, host) do
    case host.cpu_used_cores do
      nil -> {"idle", nil, []}
      used -> {if(used >= T.working_cpu_cores(), do: "working", else: "idle"), nil, []}
    end
  end

  def resource_node(:mem, host) do
    frac = host.mem_used_bytes / host.mem_total_bytes

    if frac > T.host_memory_warn() do
      reason = "memory #{Format.percent(frac)} used"
      {"blocked", reason, [{"warn", "host #{reason}"}]}
    else
      {"working", nil, []}
    end
  end

  def resource_node(:disk, host) do
    frac = disk_fraction(host)

    cond do
      frac > T.disk_alert() ->
        {"blocked", "disk #{Format.percent(frac)} full",
         [{"alert", "host disk #{Format.percent(frac)} full"}]}

      frac > T.disk_warn() ->
        {"blocked", "disk #{Format.percent(frac)} full",
         [{"warn", "host disk #{Format.percent(frac)} full"}]}

      true ->
        {"working", nil, []}
    end
  end

  @doc "df's Use%: used / (used + available to non-root)."
  def disk_fraction(host) do
    host.disk_used_bytes / (host.disk_used_bytes + host.disk_avail_bytes)
  end

  @doc """
  A node whose report (what `ObsFactor.Reports` read for it, nil when it has
  none or nothing was read) is failing: a warning, never a status. The app
  may be fine and merely not reporting.
  """
  @doc """
  A scaled service whose other replicas are not all running. The node's own
  container is the first running one, so it says nothing about the rest; a
  stopped replica also drops out of the service's DNS name, and with it out
  of the report's members, so without this a cluster down a node reads as a
  smaller healthy one. An alert: the service is running short.
  """
  def replicas(_label, nil), do: []

  def replicas(label, c) do
    others = Map.get(c, :replicas, [])
    down = Enum.reject(others, &(&1.state == "running"))

    case down do
      [] -> []
      _ ->
        total = length(others) + 1
        [{"alert", "#{label}: #{total - length(down)} of #{total} replicas running (#{Enum.map_join(down, ", ", &"#{&1.name} #{&1.state}")})"}]
    end
  end

  def report(_label, nil), do: []
  def report(_label, %{ok: true}), do: []

  def report(label, %{ok: false, error: error}),
    do: [{"warn", "#{label} report failing: #{error}"}]

  @send_queue_warn 1_000_000

  @doc """
  What the nodes of a cluster say about each other (`members` of a report:
  one per node, each with its own `cluster` view). One node's view cannot
  show a partition; side by side they can:

    * A lists B and B, answering, does not list A: a partial partition.
    * A, answering, does not list B, which answers: not connected.
    * two nodes say a :global name lives in different places.
    * a connection with more than 1 MB waiting to be sent: the far side is
      not keeping up (or the link is).

  A member whose report failed says nothing either way.
  """
  def cluster(_label, nil), do: []
  def cluster(_label, [_]), do: []

  def cluster(label, members) do
    views =
      for m <- members, m.ok, c = m[:cluster], c != nil, into: %{} do
        {c.node, MapSet.new(c.connections, & &1.node)}
      end

    names = Map.keys(views)

    pairs =
      for a <- names, b <- names, a < b do
        a_sees = MapSet.member?(views[a], b)
        b_sees = MapSet.member?(views[b], a)

        cond do
          a_sees and b_sees -> nil
          a_sees -> {"alert", "#{label}: #{a} lists #{b}, which does not list it back (a partial partition)"}
          b_sees -> {"alert", "#{label}: #{b} lists #{a}, which does not list it back (a partial partition)"}
          true -> {"alert", "#{label}: #{a} and #{b} are not connected"}
        end
      end

    queues =
      for m <- members, m.ok, c = m[:cluster], c != nil, conn <- c.connections,
          is_number(conn.send_queue_bytes) and conn.send_queue_bytes > @send_queue_warn do
        {"warn", "#{label}: #{Format.bytes(conn.send_queue_bytes)} queued on #{c.node} for #{conn.node}"}
      end

    globals =
      members
      |> Enum.flat_map(fn m -> if m.ok && m[:cluster], do: m.cluster.globals, else: [] end)
      |> Enum.group_by(& &1.name, & &1.node)
      |> Enum.flat_map(fn {name, homes} ->
        case Enum.uniq(homes) do
          [_] -> []
          many -> [{"alert", "#{label}: the nodes disagree where #{name} lives (#{Enum.join(Enum.sort(many), ", ")})"}]
        end
      end)

    Enum.reject(pairs, &is_nil/1) ++ queues ++ globals
  end

  @doc "One alert per failing source."
  def sources(sources) do
    for {name, %{ok: false, error: error}} <- Enum.sort(sources) do
      {"alert", "#{name} source failing: #{error}"}
    end
  end

  @doc "Worst first: alerts, then warnings; stable within a severity."
  def order(attention) do
    Enum.sort_by(attention, fn %{severity: s} -> if s == "alert", do: 0, else: 1 end)
  end
end
