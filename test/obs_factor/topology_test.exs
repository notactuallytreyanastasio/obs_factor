defmodule ObsFactor.TopologyTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Topology

  defp base do
    %{
      platforms: [%{id: "main", label: "main"}],
      nodes: [
        %{
          id: "caddy",
          label: "Caddy",
          kind: :proxy,
          service: "caddy",
          platform: "main",
          pos: {0, 0}
        },
        %{
          id: "web",
          label: "Web",
          kind: :app,
          service: "web",
          platform: "main",
          pos: {1, 0},
          hosts: ["w.test"]
        }
      ],
      edges: []
    }
  end

  defp error_for(term) do
    assert {:error, message} = Topology.validate(term)
    message
  end

  test "loads the test topology" do
    t = ObsFactor.Fixtures.topology()
    assert Enum.find(t.nodes, &(&1.id == "blimp-blog")).pos == [4, 2]
    assert Enum.find(t.nodes, &(&1.id == "soldat")).via == ["bobbby.online/arena/*"]
  end

  test "a valid map" do
    assert {:ok, t} = Topology.validate(base())

    assert [%{id: "caddy"}, %{id: "web", hosts: ["w.test"], via: [], databases: [], probe: nil}] =
             t.nodes
  end

  test "errors name the offending entry" do
    assert error_for(put_in(base(), [:nodes, Access.at(1), :kind], :bogus)) =~
             ~s(node "web": kind must be one of)

    assert error_for(put_in(base(), [:nodes, Access.at(1), :platform], "nope")) =~
             ~s(node "web": platform "nope" is not in :platforms)

    assert error_for(put_in(base(), [:nodes, Access.at(1), :pos], {1})) =~
             ~s(node "web": pos must be)

    assert error_for(put_in(base(), [:nodes, Access.at(1), :probe], "ftp://x")) =~
             ~s(node "web": probe must be an http)

    assert error_for(put_in(base(), [:nodes, Access.at(1), :colour], "red")) =~
             ~s(node "web": unknown keys [:colour])

    assert error_for(update_in(base(), [:nodes, Access.at(1)], &Map.delete(&1, :service))) =~
             ~s(node "web": kind :app needs :service or :container)

    assert error_for(put_in(base(), [:nodes, Access.at(1), :id], "internet")) =~ "reserved"

    assert error_for(put_in(base(), [:edges], [%{from: "web", to: "nowhere", item: "x"}])) =~
             ~s(edge web -> nowhere: no node "nowhere")

    assert error_for(put_in(base(), [:edges], [%{from: "caddy", to: "web", item: "x"}])) =~
             "duplicates a derived"

    assert error_for(update_in(base(), [:nodes], &(&1 ++ [hd(tl(&1))]))) =~
             ~s(duplicate node id ["web"])

    assert error_for(Map.put(base(), :extra, 1)) =~ "unknown top-level keys"
    assert error_for([]) =~ "must evaluate to a map"
  end

  test "a host may belong to one node only" do
    other = %{
      id: "web2",
      label: "Web 2",
      kind: :app,
      service: "web2",
      platform: "main",
      pos: {2, 0},
      hosts: ["w.test"]
    }

    assert error_for(update_in(base(), [:nodes], &(&1 ++ [other]))) =~
             ~s(host "w.test" is claimed by nodes ["web", "web2"])
  end

  test "load! names the file and the problem" do
    path =
      Path.join(System.tmp_dir!(), "obs_factor_topo_#{System.unique_integer([:positive])}.exs")

    File.write!(path, inspect(put_in(base(), [:nodes, Access.at(0), :kind], :router)))
    on_exit(fn -> File.rm(path) end)

    assert_raise Topology.Error, ~r/#{Regex.escape(path)}: node "caddy": kind must be/, fn ->
      Topology.load!(path)
    end

    assert_raise Topology.Error, ~r/does not exist/, fn -> Topology.load!(path <> ".missing") end
  end
end
