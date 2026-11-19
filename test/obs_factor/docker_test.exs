defmodule ObsFactor.DockerTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Docker
  alias ObsFactor.Docker.Parse
  alias ObsFactor.Fixtures

  setup_all do
    {:ok, cap: Fixtures.capture()}
  end

  describe "container list" do
    test "parses all 19 real entries", %{cap: cap} do
      entries = Enum.map(cap["containers"], &Parse.list_entry/1)
      assert length(entries) == 19
      assert Enum.count(entries, &(&1.state == "running")) == 18

      temper = Enum.find(entries, &(&1.name == "temper-link"))
      assert temper.state == "exited"
      assert temper.oneoff
      assert temper.service == "marginalia"

      caddy = Enum.find(entries, &(&1.name == "blog-caddy-1"))
      assert caddy.service == "caddy"
      refute caddy.oneoff
    end
  end

  describe "inspect" do
    test "keeps the fields we use and nothing else", %{cap: cap} do
      body =
        put_in(cap["inspect"]["blog-blimp-blog-1"], ["Config", "Env"], ["DB_PASSWORD=hunter2"])

      raw = Jason.encode!(body)

      assert {:ok, parsed} = Parse.inspect_body(raw)
      assert parsed.running
      assert parsed.restart_count == 0
      assert parsed.memory_limit == 1_610_612_736
      assert parsed.restart_policy == "always"
      assert parsed.started_at == ~U[2026-11-05 16:37:17.191990Z]
      refute inspect(parsed, limit: :infinity) =~ "hunter2"
      refute Map.has_key?(parsed, :env)
    end

    test "Memory 0 is no limit; health is read when present", %{cap: cap} do
      assert {:ok, db} = Parse.inspect_body(Jason.encode!(cap["inspect"]["blog-db-1"]))
      assert db.memory_limit == nil
      assert db.health == "healthy"
    end

    test "the exited one-off", %{cap: cap} do
      assert {:ok, t} = Parse.inspect_body(Jason.encode!(cap["inspect"]["temper-link"]))
      refute t.running
      assert t.status == "exited"
      assert t.exit_code == 0
      assert t.restart_policy == "no"
      assert t.finished_at == ~U[2026-09-20 19:04:47.451246Z]
    end

    test "an unexpected body is an error that never quotes the body" do
      secret =
        ~s({"Config":{"Env":["API_KEY=sk-live-123"]},"State":{"Status":"running"},"HostConfig":{}})

      assert {:error, message} = Parse.inspect_body(secret)
      assert message =~ "Running"
      refute message =~ "sk-live"

      truncated = ~s({"Config":{"Env":["API_KEY=sk-live-123"]},"State":)
      assert {:error, message} = Parse.inspect_body(truncated)
      refute message =~ "sk-live"
    end
  end

  describe "stats" do
    test "memory is usage minus inactive_file (cgroup v2)", %{cap: cap} do
      s = Parse.stats(cap["stats_b"]["blog-blimp-blog-1"])
      raw = cap["stats_b"]["blog-blimp-blog-1"]["memory_stats"]
      assert s.mem_bytes == raw["usage"] - raw["stats"]["inactive_file"]
      assert s.mem_bytes == 361_529_344
    end

    test "cgroup v1 total_inactive_file is used when that is what exists", %{cap: cap} do
      body =
        update_in(cap["stats_b"]["blog-db-1"], ["memory_stats", "stats"], fn st ->
          st |> Map.delete("inactive_file") |> Map.put("total_inactive_file", 1000)
        end)

      assert Parse.stats(body).mem_bytes == body["memory_stats"]["usage"] - 1000
    end

    test "rates across the two real samples 5 s apart", %{cap: cap} do
      a = Parse.stats(cap["stats_a"]["blog-blimp-blog-1"])
      b = Parse.stats(cap["stats_b"]["blog-blimp-blog-1"])
      r = Docker.rates(a, b)

      # docker stats' formula; the same as wall-clock delta to within 0.2%.
      assert_in_delta r.cpu_cores, 0.006659, 0.000001
      assert_in_delta r.net_rx_bps, 43_173.6, 0.5
      assert_in_delta r.net_tx_bps, 1950.05, 0.05

      db =
        Docker.rates(
          Parse.stats(cap["stats_a"]["blog-db-1"]),
          Parse.stats(cap["stats_b"]["blog-db-1"])
        )

      assert_in_delta db.cpu_cores, 0.010997, 0.000001
    end

    test "a counter reset (same id, restarted) gives nil, not a negative", %{cap: cap} do
      a = Parse.stats(cap["stats_b"]["blog-app-1"])
      b = Parse.stats(cap["stats_a"]["blog-app-1"])
      b = %{b | read_at: DateTime.add(a.read_at, 5), system_ns: a.system_ns + 20_000_000_000}
      r = Docker.rates(a, b)
      assert r.cpu_cores == nil
      assert r.net_rx_bps == nil
    end
  end

  describe "assemble" do
    test "first sample has no rates; second has them; restarts are counted in the window" do
      data = Fixtures.docker()
      blog = Enum.find(data.containers, &(&1.name == "blog-blimp-blog-1"))
      assert_in_delta blog.cpu_cores, 0.00666, 0.00001
      assert blog.mem_bytes == 361_529_344
      assert blog.restarts_recent == 0

      classifier = Enum.find(data.containers, &(&1.name == "blog-classifier-1"))
      assert classifier.cpu_cores == nil
    end

    test "a restart count that climbs is a recent restart" do
      cap = Fixtures.capture()

      entry =
        cap["containers"]
        |> Enum.map(&Parse.list_entry/1)
        |> Enum.find(&(&1.name == "blog-blimp-blog-1"))

      {:ok, i} = Parse.inspect_body(Jason.encode!(cap["inspect"]["blog-blimp-blog-1"]))

      state = %{samples: %{}, restarts: %{}}

      final =
        Enum.reduce(0..3, state, fn n, st ->
          d = [%{entry: entry, inspect: {:ok, %{i | restart_count: n}}, stats: :not_running}]
          {[c], samples, restarts} = Docker.assemble(d, st, 1_000_000 + n * 5_000)
          send(self(), {:recent, c.restarts_recent})
          %{st | samples: samples, restarts: restarts}
        end)

      assert final.restarts[entry.id] |> length() == 4
      assert_received {:recent, 0}
      assert_received {:recent, 3}
    end
  end
end
