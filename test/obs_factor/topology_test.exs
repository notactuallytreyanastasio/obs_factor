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

  test "style is optional and passed through" do
    assert {:ok, t} = Topology.validate(base())
    assert Enum.map(t.nodes, & &1.style) == [nil, nil]

    for style <- ["press", "press-2", "a"] do
      assert {:ok, t} = Topology.validate(put_in(base(), [:nodes, Access.at(1), :style], style))
      assert Enum.map(t.nodes, & &1.style) == [nil, style]
    end
  end

  test "a bad style names the node and the value" do
    for bad <- ["Press", "2press", "-press", "press_room", "press room", "", "press\n"] do
      assert error_for(put_in(base(), [:nodes, Access.at(1), :style], bad)) =~
               ~s(node "web": style must match ) <>
                 inspect(~r/\A[a-z][a-z0-9-]*\z/) <>
                 ", got #{inspect(bad)}"
    end

    for bad <- [:press, 7, ["press"]] do
      assert error_for(put_in(base(), [:nodes, Access.at(1), :style], bad)) =~
               ~s(node "web": style must be a string matching)

      assert error_for(put_in(base(), [:nodes, Access.at(1), :style], bad)) =~
               "got #{inspect(bad)}"
    end
  end

  # The files the app boots from. Their content belongs to the lab and the
  # frontend; this only says they still load.
  for path <- Path.wildcard(Path.expand("../../priv/topology/*.exs", __DIR__)) do
    test "the real topology #{Path.basename(path)} loads and validates" do
      t = Topology.load!(unquote(path))
      assert t.nodes != []

      for n <- t.nodes do
        assert n.style == nil or n.style =~ ~r/\A[a-z][a-z0-9-]*\z/
      end
    end
  end

  test "both real topology files are there to be checked" do
    names =
      Path.expand("../../priv/topology/*.exs", __DIR__)
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)

    assert "prod.exs" in names and "lab.exs" in names
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

  test "report is optional, an http(s) URL, and passed through" do
    assert {:ok, t} = Topology.validate(base())
    assert Enum.map(t.nodes, & &1.report) == [nil, nil]

    for url <- ["http://web:9568/report", "https://web.test/report"] do
      assert {:ok, t} = Topology.validate(put_in(base(), [:nodes, Access.at(1), :report], url))
      assert Enum.map(t.nodes, & &1.report) == [nil, url]
    end

    # The proxy is a container too.
    assert {:ok, _} =
             Topology.validate(put_in(base(), [:nodes, Access.at(0), :report], "http://caddy/r"))

    assert Enum.find(ObsFactor.Fixtures.topology().nodes, &(&1.id == "app")).report ==
             "http://app:9568/report"
  end

  test "a bad report names the node and the value" do
    for bad <- ["ftp://web/report", "web:9568/report", "/report", "http://", ""] do
      assert error_for(put_in(base(), [:nodes, Access.at(1), :report], bad)) ==
               ~s|node "web": report must be an http(s) URL, got #{inspect(bad)}|
    end

    assert error_for(put_in(base(), [:nodes, Access.at(1), :report], :yes)) ==
             ~s(node "web": report must be a URL string or nil, got :yes)
  end

  test "only a container can report" do
    platforms = [%{id: "main", label: "main"}]

    static = %{
      id: "site",
      label: "Site",
      kind: :static,
      site: "site",
      platform: "main",
      pos: {0, 1},
      report: "http://site/report"
    }

    external = %{
      id: "api",
      label: "API",
      kind: :external,
      platform: "main",
      pos: {0, 2},
      report: "http://api/report"
    }

    assert error_for(%{platforms: platforms, nodes: [static]}) ==
             ~s(node "site": kind :static has no process to report; drop :report)

    assert error_for(%{platforms: platforms, nodes: [external]}) ==
             ~s(node "api": kind :external has no process to report; drop :report)

    for kind <- [:app, :relay, :proxy, :db] do
      node = %{
        id: "n",
        label: "N",
        kind: kind,
        service: "n",
        platform: "main",
        pos: {0, 0},
        report: "http://n:9568/report"
      }

      assert {:ok, %{nodes: [%{report: "http://n:9568/report"}]}} =
               Topology.validate(%{platforms: platforms, nodes: [node]})
    end
  end
end
