defmodule ObsFactor.Topology do
  @moduledoc """
  Loads and validates a topology file (`priv/topology/*.exs`, see
  docs/contract.md). The file evaluates to a map; every problem is reported
  with the entry that caused it, and the boot stops.

  The topology names and places what we know about. It never decides what
  exists: containers come from Docker.
  """

  defmodule Error do
    defexception [:message]
  end

  @kinds [:proxy, :app, :relay, :db, :static, :external]
  @reserved_ids ["internet", "host-cpu", "host-mem", "host-disk"]

  @node_keys [
    :id,
    :label,
    :kind,
    :service,
    :container,
    :site,
    :platform,
    :pos,
    :hosts,
    :via,
    :probe,
    :databases
  ]

  @type t :: %{platforms: [map], nodes: [map], edges: [map]}

  def reserved_ids, do: @reserved_ids

  @doc "Evaluates and validates the file at `path`. Raises `Topology.Error`."
  def load!(path) do
    unless File.regular?(path) do
      raise Error, "topology file #{inspect(path)} does not exist"
    end

    {term, _binding} =
      try do
        Code.eval_file(path)
      rescue
        e -> raise Error, "topology #{path}: does not evaluate: #{Exception.message(e)}"
      end

    case validate(term) do
      {:ok, topology} -> topology
      {:error, message} -> raise Error, "topology #{path}: #{message}"
    end
  end

  @doc "Validates an already evaluated topology term."
  def validate(term) do
    {:ok, validate!(term)}
  catch
    {:invalid, message} -> {:error, message}
  end

  defp validate!(term) when is_map(term) do
    unknown = Map.keys(term) -- [:platforms, :nodes, :edges]
    unknown != [] && fail("unknown top-level keys #{inspect(unknown)}")

    platforms = list!(Map.get(term, :platforms), "platforms")
    nodes = list!(Map.get(term, :nodes), "nodes")
    edges = list!(Map.get(term, :edges, []), "edges")

    platforms = Enum.map(platforms, &platform!/1)
    unique!(Enum.map(platforms, & &1.id), "platform id")
    platform_ids = MapSet.new(platforms, & &1.id)

    nodes = Enum.map(nodes, &node!(&1, platform_ids))
    unique!(Enum.map(nodes, & &1.id), "node id")

    nodes
    |> Enum.flat_map(fn n -> Enum.map(n.hosts, &{&1, n.id}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn
      {_host, [_]} -> :ok
      {host, ids} -> fail("host #{inspect(host)} is claimed by nodes #{inspect(ids)}")
    end)

    nodes
    |> Enum.filter(& &1.service)
    |> Enum.group_by(& &1.service, & &1.id)
    |> Enum.each(fn
      {_service, [_]} -> :ok
      {service, ids} -> fail("service #{inspect(service)} is claimed by nodes #{inspect(ids)}")
    end)

    for kind <- [:proxy, :db] do
      case Enum.filter(nodes, &(&1.kind == kind)) do
        many when length(many) > 1 ->
          fail(
            "at most one node may be kind #{inspect(kind)}, found #{inspect(Enum.map(many, & &1.id))}"
          )

        _ ->
          :ok
      end
    end

    known_ids = MapSet.new(Enum.map(nodes, & &1.id) ++ @reserved_ids)
    edges = Enum.map(edges, &edge!(&1, known_ids))
    topology = %{platforms: platforms, nodes: nodes, edges: edges}

    derived = topology |> derived_edge_keys() |> MapSet.new()

    Enum.each(edges, fn e ->
      if MapSet.member?(derived, {e.from, e.to}) do
        fail("edge #{e.from} -> #{e.to} duplicates a derived (metered) belt")
      end
    end)

    unique!(Enum.map(edges, &"#{&1.from}>#{&1.to}"), "edge")
    topology
  end

  defp validate!(other), do: fail("must evaluate to a map, got #{inspect(other, limit: 5)}")

  @doc "The {from, to} pairs of the belts the snapshot derives."
  def derived_edge_keys(%{nodes: nodes}) do
    proxy = Enum.find(nodes, &(&1.kind == :proxy))
    db = Enum.find(nodes, &(&1.kind == :db))

    internet = if proxy, do: [{"internet", proxy.id}], else: []

    to_nodes =
      if proxy do
        for n <- nodes, n.hosts != [] or n.via != [], do: {proxy.id, n.id}
      else
        []
      end

    to_db = if db, do: for(n <- nodes, n.databases != [], do: {n.id, db.id}), else: []
    internet ++ to_nodes ++ to_db
  end

  defp platform!(%{id: id, label: label} = p) when is_binary(id) and is_binary(label) do
    unknown = Map.keys(p) -- [:id, :label]
    unknown != [] && fail("platform #{inspect(id)}: unknown keys #{inspect(unknown)}")
    %{id: id, label: label}
  end

  defp platform!(p), do: fail("platform #{inspect(p)}: needs string :id and :label")

  defp node!(%{id: id} = n, platform_ids) when is_binary(id) do
    where = "node #{inspect(id)}"
    unknown = Map.keys(n) -- @node_keys
    unknown != [] && fail("#{where}: unknown keys #{inspect(unknown)}")

    id in @reserved_ids && fail("#{where}: id is reserved for a built-in node")

    label = string!(n, :label, where)
    kind = Map.get(n, :kind)

    kind in @kinds ||
      fail("#{where}: kind must be one of #{inspect(@kinds)}, got #{inspect(kind)}")

    platform = string!(n, :platform, where)

    MapSet.member?(platform_ids, platform) ||
      fail("#{where}: platform #{inspect(platform)} is not in :platforms")

    pos =
      case Map.get(n, :pos) do
        {c, r} when is_integer(c) and is_integer(r) and c >= 0 and r >= 0 ->
          [c, r]

        other ->
          fail("#{where}: pos must be {col, row} non-negative integers, got #{inspect(other)}")
      end

    service = optional_string!(n, :service, where)
    container = optional_string!(n, :container, where)
    site = optional_string!(n, :site, where)

    service && container && fail("#{where}: give :service or :container, not both")

    needs_container = kind in [:proxy, :app, :relay, :db]

    if needs_container and service == nil and container == nil do
      fail("#{where}: kind #{inspect(kind)} needs :service or :container")
    end

    if not needs_container and (service || container) do
      fail("#{where}: kind #{inspect(kind)} has no container; drop :service/:container")
    end

    (kind == :static and site == nil) && fail("#{where}: kind :static needs :site")
    (kind != :static and site != nil) && fail("#{where}: only kind :static takes :site")

    hosts = string_list!(n, :hosts, where)
    via = string_list!(n, :via, where)
    databases = string_list!(n, :databases, where)

    (kind == :proxy and hosts != []) &&
      fail("#{where}: the proxy lists hosts from Caddy itself; drop :hosts")

    probe =
      case Map.get(n, :probe) do
        nil ->
          nil

        url when is_binary(url) ->
          case URI.parse(url) do
            %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" ->
              url

            _ ->
              fail("#{where}: probe must be an http(s) URL, got #{inspect(url)}")
          end

        other ->
          fail("#{where}: probe must be a URL string or nil, got #{inspect(other)}")
      end

    %{
      id: id,
      label: label,
      kind: kind,
      platform: platform,
      pos: pos,
      service: service,
      container: container,
      site: site,
      hosts: hosts,
      via: via,
      probe: probe,
      databases: databases
    }
  end

  defp node!(n, _), do: fail("node #{inspect(n, limit: 5)}: needs a string :id")

  defp edge!(%{from: from, to: to, item: item} = e, known)
       when is_binary(from) and is_binary(to) and is_binary(item) do
    where = "edge #{from} -> #{to}"
    unknown = Map.keys(e) -- [:from, :to, :item]
    unknown != [] && fail("#{where}: unknown keys #{inspect(unknown)}")
    MapSet.member?(known, from) || fail("#{where}: no node #{inspect(from)}")
    MapSet.member?(known, to) || fail("#{where}: no node #{inspect(to)}")
    %{from: from, to: to, item: item}
  end

  defp edge!(e, _), do: fail("edge #{inspect(e)}: needs string :from, :to and :item")

  defp list!(l, _what) when is_list(l), do: l
  defp list!(other, what), do: fail("#{what} must be a list, got #{inspect(other, limit: 5)}")

  defp string!(map, key, where) do
    case Map.get(map, key) do
      s when is_binary(s) and s != "" -> s
      other -> fail("#{where}: #{inspect(key)} must be a non-empty string, got #{inspect(other)}")
    end
  end

  defp optional_string!(map, key, where) do
    case Map.get(map, key) do
      nil -> nil
      _ -> string!(map, key, where)
    end
  end

  defp string_list!(map, key, where) do
    case Map.get(map, key, []) do
      l when is_list(l) ->
        Enum.all?(l, &(is_binary(&1) and &1 != "")) ||
          fail("#{where}: #{inspect(key)} must be a list of strings, got #{inspect(l)}")

        l

      other ->
        fail("#{where}: #{inspect(key)} must be a list of strings, got #{inspect(other)}")
    end
  end

  defp unique!(ids, what) do
    case ids -- Enum.uniq(ids) do
      [] -> :ok
      dups -> fail("duplicate #{what} #{inspect(Enum.uniq(dups))}")
    end
  end

  defp fail(message), do: throw({:invalid, message})
end
