defmodule ObsFactor.Discovery do
  @moduledoc """
  Apps that connect themselves: a container labelled
  `obs_factor.report=http://<service>:9568/report` is put on the floor at
  runtime, merged with the static topology, with no edit to
  `priv/topology/*.exs` and no restart (docs/CONNECT.md).

  Labels read (from `/containers/json`, which the docker-proxy already
  allows; `ObsFactor.Docker.Parse` strips the `obs_factor.` prefix):

  | label | meaning |
  |---|---|
  | `obs_factor.report` | required: the factory_report URL |
  | `obs_factor.label` | the building's name (default: the id) |
  | `obs_factor.hosts` | Caddy hosts, comma separated |
  | `obs_factor.databases` | Postgres database names, comma separated |
  | `obs_factor.platform` | a platform id of the topology (default: the proxy's) |
  | `obs_factor.probe` | an http(s) URL to probe |
  | `obs_factor.id` | the node id (default: the compose service) |

  **The static topology wins.** When a static node already claims the
  container (same compose service, or same container name):

    * a field the static node leaves empty (`report`, `hosts`, `databases`,
      `probe`) is filled from the label;
    * a field it sets and the label contradicts keeps the static value, and
      the contradiction is a `warn` in attention, naming both values.

  A container no static node claims becomes a node of kind `:app` with
  `pos: nil` (the next free slot of its platform). Its id, a host, a
  platform or a URL that would break a topology rule is reported, never
  dropped silently: a taken id leaves the container unplaced; a taken host
  is left off the node; an unknown platform falls back to the default.

  Pure apart from `topology/0` and `report_targets/0`, which read the
  latest Docker result from `ObsFactor.Sources`.
  """

  @id ~r/\A[a-z][a-z0-9-]{0,40}\z/

  @doc """
  `{topology, problems}`: `topology` with every report-labelled container
  merged in, problems as `{"warn", text}`.
  """
  def merge(topology, containers) do
    platforms = MapSet.new(topology.platforms, & &1.id)
    default_platform = default_platform(topology)

    containers
    |> labelled()
    |> Enum.reduce({topology.nodes, []}, fn c, {nodes, problems} ->
      case Enum.find(nodes, &claims?(&1, c)) do
        nil ->
          {node, more} = new_node(c, nodes, platforms, default_platform)
          {if(node, do: nodes ++ [node], else: nodes), problems ++ more}

        static ->
          {filled, more} = fill(static, c, nodes)
          {Enum.map(nodes, &if(&1.id == static.id, do: filled, else: &1)), problems ++ more}
      end
    end)
    |> then(fn {nodes, problems} -> {%{topology | nodes: nodes}, problems} end)
  end

  @doc """
  The containers that carry `obs_factor.report`, one per compose service
  (the first by name: replicas of a scaled service are one node). One-off
  containers (`docker compose run`) never connect.
  """
  def labelled(containers) do
    containers
    |> Enum.filter(&Map.has_key?(Map.get(&1, :labels) || %{}, "report"))
    |> Enum.reject(&Map.get(&1, :oneoff, false))
    |> Enum.sort_by(& &1.name)
    |> Enum.uniq_by(&(&1.service || {:name, &1.name}))
  end

  @doc "The static topology merged with the containers Docker listed last."
  def topology do
    static = ObsFactor.topology()

    case containers() do
      [] -> static
      cs -> cs |> then(&merge(static, &1)) |> elem(0)
    end
  end

  @doc """
  Report targets `merge/2` adds to the static ones: `[{id, url}]` for every
  node whose `report` came from a label.
  """
  def report_targets(static, containers) do
    {merged, _} = merge(static, containers)
    before = Map.new(static.nodes, &{&1.id, Map.get(&1, :report)})
    for n <- merged.nodes, n[:report], Map.get(before, n.id) == nil, do: {n.id, n.report}
  end

  @doc "`report_targets/2` against the live topology and Docker's last list."
  def report_targets do
    case containers() do
      [] -> []
      cs -> report_targets(ObsFactor.topology(), cs)
    end
  rescue
    # no topology yet (a test that never booted one): nothing to add
    ArgumentError -> []
  end

  defp containers do
    case ObsFactor.Sources.get(:docker) do
      %{ok: true, data: %{containers: cs}} -> cs
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  ## Claimed by a static node: fill the gaps, report the contradictions

  defp claims?(node, c) do
    (node[:container] != nil and node.container == c.name) or
      (node[:service] != nil and node.service == c.service and c.service != nil)
  end

  defp fill(static, c, nodes) do
    l = c.labels
    where = "container #{c.name} (node #{static.id})"

    with {:ok, report} <- url(l, "report", where) do
      probe = case url(l, "probe", where) do {:ok, p} -> p; {:error, _} -> nil end
      taken = taken_hosts(nodes, static.id)
      {hosts, host_problems} = free_hosts(split(l["hosts"]), taken, where)

      {node, problems} =
        {static, host_problems ++ bad_url(l, "probe", where)}
        |> field(:report, report, where, "report")
        |> then(fn {n, p} -> {if(static.report == nil, do: Map.put(n, :labelled_report, true), else: n), p} end)
        |> field(:probe, probe, where, "probe")
        |> field(:hosts, hosts, where, "hosts")
        |> field(:databases, split(l["databases"]), where, "databases")

      problems =
        problems ++
          same_or_warn(l["label"], static.label, where, "label") ++
          same_or_warn(l["platform"], static.platform, where, "platform") ++
          same_or_warn(l["id"], static.id, where, "id")

      {node, problems}
    else
      {:error, why} -> {static, [{"warn", "#{where}: labels not used: #{why}"}]}
    end
  end

  # Empty on the static node: take the label's. Set and different: keep it, say so.
  defp field({node, problems}, key, value, where, name) do
    current = Map.get(node, key)

    cond do
      value in [nil, []] -> {node, problems}
      current in [nil, []] -> {Map.put(node, key, value), problems}
      current == value -> {node, problems}
      true -> {node, problems ++ [conflict(where, name, value, current)]}
    end
  end

  defp same_or_warn(nil, _static, _where, _name), do: []
  defp same_or_warn(v, v, _where, _name), do: []
  defp same_or_warn(v, static, where, name), do: [conflict(where, name, v, static)]

  defp conflict(where, name, label, static) do
    {"warn",
     "#{where}: obs_factor.#{name} says #{show(label)}, the topology says #{show(static)}; the topology wins"}
  end

  defp show(l) when is_list(l), do: inspect(Enum.join(l, ","))
  defp show(v), do: inspect(v)

  ## Claimed by nobody: a node of its own

  defp new_node(c, nodes, platforms, default_platform) do
    l = c.labels
    id = l["id"] || slug(c.service || c.name)
    where = "container #{c.name}"
    taken_ids = MapSet.new(Enum.map(nodes, & &1.id) ++ ObsFactor.Topology.reserved_ids())

    cond do
      not Regex.match?(@id, id) ->
        {nil, [{"warn", "#{where}: not placed: id #{inspect(id)} is not a lowercase id (set obs_factor.id)"}]}

      MapSet.member?(taken_ids, id) ->
        {nil, [{"warn", "#{where}: not placed: id #{inspect(id)} is already a node; the topology wins (set obs_factor.id)"}]}

      true ->
        case url(l, "report", where) do
          {:error, why} ->
            {nil, [{"warn", "#{where}: not placed: #{why}"}]}

          {:ok, report} ->
            {hosts, host_problems} = free_hosts(split(l["hosts"]), taken_hosts(nodes, nil), where)
            {platform, platform_problems} = platform(l["platform"], platforms, default_platform, where)
            probe = case url(l, "probe", where) do {:ok, p} -> p; {:error, _} -> nil end

            node = %{
              id: id,
              label: l["label"] || id,
              kind: :app,
              style: nil,
              # the compose service when there is one, so a scaled service is
              # one node with replicas, as for a topology entry
              service: c.service,
              container: if(c.service, do: nil, else: c.name),
              site: nil,
              platform: platform,
              pos: nil,
              hosts: hosts,
              via: [],
              probe: probe,
              report: report,
              databases: split(l["databases"]),
              # the keys Topology.validate/1 gives every node (deploys, chapter 33):
              # nil here, so ObsFactor.Deploys guesses the .deployed path from the service
              deployed: nil,
              repo: nil,
              discovered: true,
              labelled_report: true
            }

            {node, host_problems ++ platform_problems ++ bad_url(l, "probe", where)}
        end
    end
  end

  defp default_platform(topology) do
    case Enum.find(topology.nodes, &(&1.kind == :proxy)) do
      %{platform: p} -> p
      nil -> nil
    end
  end

  defp platform(nil, _known, default, _where), do: {default, []}

  defp platform(p, known, default, where) do
    if MapSet.member?(known, p),
      do: {p, []},
      else: {default, [{"warn", "#{where}: obs_factor.platform #{inspect(p)} is not a platform of the topology; placed on #{inspect(default)}"}]}
  end

  ## Shared

  defp taken_hosts(nodes, except_id) do
    for n <- nodes, n.id != except_id, h <- Map.get(n, :hosts) || [], into: %{}, do: {h, n.id}
  end

  defp free_hosts(hosts, taken, where) do
    {free, stolen} = Enum.split_with(hosts, &(not Map.has_key?(taken, &1)))

    {free,
     for h <- stolen do
       {"warn", "#{where}: host #{inspect(h)} belongs to node #{taken[h]}; the topology wins, left off"}
     end}
  end

  defp url(l, key, _where) do
    case l[key] do
      nil when key == "report" -> {:error, "obs_factor.report is empty"}
      nil -> {:ok, nil}
      u -> if http_url?(u), do: {:ok, u}, else: {:error, "obs_factor.#{key} #{inspect(u)} is not an http(s) URL"}
    end
  end

  defp bad_url(l, key, where) do
    case url(l, key, where) do
      {:ok, _} -> []
      {:error, why} -> [{"warn", "#{where}: #{why}; not used"}]
    end
  end

  defp http_url?(u) do
    case URI.parse(u) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> true
      _ -> false
    end
  end

  defp split(nil), do: []

  defp split(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp slug(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9-]+/, "-") |> String.trim("-")
end
