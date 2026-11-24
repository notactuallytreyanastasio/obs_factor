defmodule ObsFactor.Labelled do
  @moduledoc """
  Topology that the box declares about itself, merged in on every tick.

  Two kinds of entry, both real data, neither from the topology file:

  - **Labelled containers.** A container started with `obs_factor.*` labels
    (the builder starts every app it makes this way) is placed like a topology
    entry: `obs_factor.id`, `obs_factor.label`, `obs_factor.kind` (`app` or
    `relay`), `obs_factor.hosts` (comma separated), `obs_factor.probe`,
    `obs_factor.platform`. It has no `pos`: the browser puts it in the next
    free slot of its platform. Labels are on `/containers/json`, which the
    docker-proxy already allows; they never carry secrets.
  - **Construction sites.** A builder job whose app has no running labelled
    container yet becomes a `:construction` node with the job's hostname, so
    the lot, its belt from Caddy and its progress are on the floor while the
    build runs (and after it fails).

  A labelled container that would break a topology rule (an id or a host that
  is already taken, a bad probe URL) is not placed. It stays an unplaced node
  and the reason is returned as a problem, which the snapshot shows as a
  warning. Nothing is dropped silently.
  """

  @id ~r/^[a-z][a-z0-9-]{0,40}$/
  @kinds %{"app" => :app, "relay" => :relay}

  @doc """
  Returns `{topology, problems, builds}`: the topology with the labelled and
  construction nodes added, problems as `{severity, text}`, and each build's
  summary by node id (to attach to whichever node carries that id).
  """
  def merge(topology, containers, jobs) do
    # obs_factor.report containers connect themselves first (ObsFactor.Discovery);
    # their obs_factor.id, if any, is theirs, not a second node here.
    {topology, discovered} = ObsFactor.Discovery.merge(topology, containers)
    platforms = MapSet.new(topology.platforms, & &1.id)

    {nodes, problems} =
      containers
      |> Enum.filter(&(Map.get(&1, :labels, %{}) |> Map.has_key?("id")))
      |> Enum.reject(&(Map.get(&1, :labels, %{}) |> Map.has_key?("report")))
      |> Enum.sort_by(& &1.name)
      |> Enum.reduce({topology.nodes, []}, fn c, {nodes, problems} ->
        case labelled_node(c, nodes, platforms) do
          {:ok, node} -> {nodes ++ [node], problems}
          {:error, why} -> {nodes, problems ++ [{"warn", "container #{c.name}: labels not used: #{why}"}]}
        end
      end)

    problems = discovered ++ problems
    latest = latest_jobs(jobs)
    listed = MapSet.new(topology.nodes, & &1.id)
    ids = MapSet.new(nodes, & &1.id)

    # A job named like a topology node is not that node: report it, and
    # never hang its progress on the real building.
    {clashing, latest} = Enum.split_with(latest, &MapSet.member?(listed, &1["name"]))

    problems =
      problems ++
        for j <- clashing, do: {"warn", "build #{j["id"]}: not drawn: #{j["name"]} is already a node in the topology"}

    {nodes, problems} =
      latest
      |> Enum.reject(&MapSet.member?(ids, &1["name"]))
      |> Enum.reduce({nodes, problems}, fn job, {nodes, problems} ->
        case construction_node(job, nodes, platforms) do
          {:ok, node} -> {nodes ++ [node], problems}
          {:error, why} -> {nodes, problems ++ [{"warn", "build #{job["id"]}: not drawn: #{why}"}]}
        end
      end)

    builds = Map.new(latest, &{&1["name"], &1})
    {%{topology | nodes: nodes}, problems, builds}
  end

  @doc "Probe targets of labelled containers that `merge/3` would place."
  def probe_targets(topology, containers) do
    {merged, _, _} = merge(topology, containers, [])
    known = MapSet.new(topology.nodes, & &1.id)
    for n <- merged.nodes, n.probe, not MapSet.member?(known, n.id), do: {n.id, n.probe}
  end

  defp latest_jobs(jobs) do
    jobs
    |> Enum.group_by(& &1["name"])
    |> Enum.map(fn {_name, js} -> Enum.max_by(js, & &1["created_at"]) end)
    |> Enum.sort_by(& &1["name"])
  end

  defp labelled_node(c, nodes, platforms) do
    l = c.labels
    id = l["id"]
    hosts = split(l["hosts"])
    taken_ids = MapSet.new(Enum.map(nodes, & &1.id) ++ ObsFactor.Topology.reserved_ids())
    taken_hosts = MapSet.new(Enum.flat_map(nodes, & &1.hosts))
    kind = Map.get(@kinds, l["kind"] || "app")

    cond do
      not Regex.match?(@id, id) ->
        {:error, "obs_factor.id #{inspect(id)} is not a lowercase id"}

      MapSet.member?(taken_ids, id) ->
        {:error, "obs_factor.id #{inspect(id)} is already a node"}

      kind == nil ->
        {:error, "obs_factor.kind #{inspect(l["kind"])} is not app or relay"}

      (h = Enum.find(hosts, &MapSet.member?(taken_hosts, &1))) != nil ->
        {:error, "host #{inspect(h)} already belongs to another node"}

      l["probe"] && not http_url?(l["probe"]) ->
        {:error, "obs_factor.probe #{inspect(l["probe"])} is not an http(s) URL"}

      true ->
        platform = l["platform"]

        {:ok,
         %{
           id: id,
           label: l["label"] || id,
           kind: kind,
           service: nil,
           container: c.name,
           site: nil,
           platform: if(MapSet.member?(platforms, platform), do: platform, else: nil),
           pos: nil,
           hosts: hosts,
           via: [],
           probe: l["probe"],
           databases: []
         }}
    end
  end

  defp construction_node(job, nodes, platforms) do
    id = job["name"]
    taken_hosts = MapSet.new(Enum.flat_map(nodes, & &1.hosts))
    hosts = [job["fqdn"]]

    cond do
      not (is_binary(id) and Regex.match?(@id, id)) ->
        {:error, "name #{inspect(id)} is not a lowercase id"}

      Enum.any?(hosts, &MapSet.member?(taken_hosts, &1)) ->
        {:error, "host #{job["fqdn"]} already belongs to another node"}

      true ->
        {:ok,
         %{
           id: id,
           label: job["label"] || id,
           kind: :construction,
           service: nil,
           container: nil,
           site: nil,
           platform: if(MapSet.member?(platforms, "built"), do: "built", else: nil),
           pos: nil,
           hosts: hosts,
           via: [],
           probe: nil,
           databases: []
         }}
    end
  end

  defp split(nil), do: []

  defp split(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp http_url?(u) do
    case URI.parse(u) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" -> true
      _ -> false
    end
  end
end
