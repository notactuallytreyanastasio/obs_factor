defmodule ObsFactor.LabelledTest do
  use ExUnit.Case, async: true

  alias ObsFactor.{Labelled, Snapshot}
  alias ObsFactor.Builder.Recipe

  @topology %{
    platforms: [%{id: "main", label: "m"}, %{id: "built", label: "built here"}],
    nodes: [
      %{id: "caddy", label: "Caddy", kind: :proxy, service: "caddy", container: nil, site: nil,
        platform: "main", pos: {0, 0}, hosts: [], via: [], probe: nil, databases: []},
      %{id: "blog", label: "Blog", kind: :app, service: "blog", container: nil, site: nil,
        platform: "main", pos: {1, 0}, hosts: ["blog.lab.test"], via: [], probe: nil, databases: []}
    ],
    edges: []
  }

  defp container(name, labels),
    do: %{id: name, name: name, image: "x", state: "running", status_text: "Up", service: nil, project: nil, oneoff: false, labels: labels}

  test "a labelled container becomes a placed node on its platform, with its host and probe" do
    c = container("obsbuild-deci", %{"id" => "deci", "label" => "Deciduous", "hosts" => "deci.lab.test", "probe" => "http://obsbuild-deci:4141/api/v1/graphs", "platform" => "built"})
    {t, problems, _} = Labelled.merge(@topology, [c], [])
    assert problems == []
    n = Enum.find(t.nodes, &(&1.id == "deci"))
    assert %{kind: :app, container: "obsbuild-deci", platform: "built", pos: nil, hosts: ["deci.lab.test"]} = n
    assert Labelled.probe_targets(@topology, [c]) == [{"deci", "http://obsbuild-deci:4141/api/v1/graphs"}]
  end

  test "labels that would steal a host or an id are refused, loudly" do
    steal = container("obsbuild-x", %{"id" => "x", "hosts" => "blog.lab.test"})
    clash = container("obsbuild-blog", %{"id" => "blog"})
    {t, problems, _} = Labelled.merge(@topology, [steal, clash], [])
    assert Enum.map(t.nodes, & &1.id) == ["caddy", "blog"]
    assert [{"warn", a}, {"warn", b}] = problems
    assert a =~ "obsbuild-blog" and a =~ "already a node"
    assert b =~ "blog.lab.test" and b =~ "another node"
  end

  test "a job with no container yet is a construction lot; once the container runs, the build rides on it" do
    job = %{"id" => "deci-1", "name" => "deci", "fqdn" => "deci.lab.test", "created_at" => "2026-11-19T00:00:00Z", "status" => "running"}
    {t, [], builds} = Labelled.merge(@topology, [], [job])
    assert %{kind: :construction, hosts: ["deci.lab.test"], platform: "built"} = Enum.find(t.nodes, &(&1.id == "deci"))
    assert builds["deci"]["id"] == "deci-1"

    c = container("obsbuild-deci", %{"id" => "deci", "hosts" => "deci.lab.test", "platform" => "built"})
    {t, [], _} = Labelled.merge(@topology, [c], [job])
    assert [%{kind: :app}] = Enum.filter(t.nodes, &(&1.id == "deci"))
  end

  test "a job named like a topology node is reported and never rides on that node" do
    job = %{"id" => "blog-1", "name" => "blog", "fqdn" => "blog.lab.test", "created_at" => "2026-11-19T00:00:00Z"}
    {t, [{"warn", w}], builds} = Labelled.merge(@topology, [], [job])
    assert w =~ "blog is already a node in the topology"
    assert builds == %{}
    assert Enum.count(t.nodes, &(&1.id == "blog")) == 1
  end

  test "only the newest job per name counts" do
    old = %{"id" => "a-1", "name" => "aa", "fqdn" => "aa.lab.test", "created_at" => "2026-11-18T00:00:00Z"}
    new = %{"id" => "a-2", "name" => "aa", "fqdn" => "aa.lab.test", "created_at" => "2026-11-19T00:00:00Z"}
    {_, _, builds} = Labelled.merge(@topology, [], [old, new])
    assert builds["aa"]["id"] == "a-2"
  end

  test "a construction lot in a snapshot reads its status from the job" do
    job = %{"id" => "deci-1", "name" => "deci", "fqdn" => "deci.lab.test", "created_at" => "2026-11-19T00:00:00Z", "mode" => "github",
            "status" => "failed", "step" => "image", "error" => "docker build: exited 1",
            "steps" => [%{"name" => "name", "state" => "done"}, %{"name" => "route", "state" => "done"}, %{"name" => "image", "state" => "failed"}, %{"name" => "check", "state" => "pending"}]}
    ok = fn data -> %{ok: true, at: ~U[2026-11-19 00:00:00Z], error: nil, data: data} end
    bad = %{ok: false, at: nil, error: "off", data: nil}
    sources = %{docker: ok.(%{containers: []}), caddy: bad, postgres: bad, host: bad, probes: ok.(%{}), sites: bad, access: bad, reports: bad,
                builder: ok.(%{domain: "lab.test", modes: ["github", "route"], jobs: [job]})}
    {s, _} = Snapshot.build(@topology, sources, Snapshot.empty_memory(), ~U[2026-11-19 00:00:05Z])
    n = Enum.find(s.nodes, &(&1.id == "deci"))
    assert n.kind == "construction" and n.status == "down"
    assert n.reason == "build failed at image: docker build: exited 1"
    assert n.headline == %{value: 50, unit: "% built"}
    assert n.build["id"] == "deci-1"
    assert s.builder == %{domain: "lab.test", modes: ["github", "route"]}
    assert Enum.any?(s.edges, &(&1.from == "caddy" and &1.to == "deci"))
    assert Enum.any?(s.attention, &(&1.node == "deci" and &1.severity == "alert"))
  end

  describe "the agent's plan" do
    setup do
      dir = Path.join(System.tmp_dir!(), "recipe-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Dockerfile"), "FROM scratch\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    @good %{"dockerfile" => "Dockerfile", "context" => ".", "port" => 4141, "health" => "/api/v1/graphs",
            "env" => %{"DECIDUOUS_BIND" => "0.0.0.0"}, "secrets" => ["DECIDUOUS_API_TOKEN"],
            "volumes" => [%{"name" => "data", "path" => "/data"}], "memory_mb" => 256}

    test "a sound plan passes with its fields", %{dir: dir} do
      assert {:ok, %{"port" => 4141, "secrets" => ["DECIDUOUS_API_TOKEN"]}} = Recipe.validate(@good, dir)
    end

    test "paths that leave the repository, and nonsense, are refused", %{dir: dir} do
      assert {:error, "dockerfile" <> _} = Recipe.validate(%{@good | "dockerfile" => "../../etc/passwd"}, dir)
      assert {:error, "context" <> _} = Recipe.validate(%{@good | "context" => "/"}, dir)
      assert {:error, "port" <> _} = Recipe.validate(%{@good | "port" => "4141"}, dir)
      assert {:error, "env" <> _} = Recipe.validate(%{@good | "env" => %{"lower" => "x"}}, dir)
      assert {:error, "volumes" <> _} = Recipe.validate(%{@good | "volumes" => [%{"name" => "../x", "path" => "/d"}]}, dir)
      assert {:error, "the agent found nothing to run: " <> _} = Recipe.validate(%{@good | "port" => nil}, dir)
    end
  end
end
