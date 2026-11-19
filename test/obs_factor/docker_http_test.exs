defmodule ObsFactor.DockerHttpTest do
  # The collector against a fake Engine API on a real socket, serving the
  # captured payloads, with one container whose stats call hangs.
  use ExUnit.Case, async: true

  alias ObsFactor.{Docker, Fixtures}

  defmodule FakeDocker do
    use Plug.Router
    plug :match
    plug :dispatch

    get "/containers/json" do
      send_json(conn, Fixtures.capture()["containers"])
    end

    get "/containers/:id/json" do
      cap = Fixtures.capture()
      c = Enum.find(cap["containers"], &(&1["Id"] == id))
      name = c["Names"] |> hd() |> String.trim_leading("/")

      body =
        cap["inspect"][name] ||
          %{
            "Id" => id,
            "RestartCount" => 0,
            "State" => %{
              "Status" => c["State"],
              "Running" => c["State"] == "running",
              "Restarting" => false,
              "OOMKilled" => false,
              "ExitCode" => 0,
              "StartedAt" => "2026-11-01T00:00:00Z",
              "FinishedAt" => "0001-01-01T00:00:00Z"
            },
            "HostConfig" => %{"Memory" => 0, "RestartPolicy" => %{"Name" => "always"}},
            "Config" => %{"Env" => ["SECRET=never-leaves"]}
          }

      send_json(conn, body)
    end

    get "/containers/:id/stats" do
      cap = Fixtures.capture()
      c = Enum.find(cap["containers"], &(&1["Id"] == id))
      name = c["Names"] |> hd() |> String.trim_leading("/")

      if name == "blog-db-1", do: Process.sleep(10_000)

      case cap["stats_a"][name] do
        nil -> send_json(conn, cap["stats_a"]["blog-app-1"])
        stats -> send_json(conn, stats)
      end
    end

    defp send_json(conn, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    {:ok, pid} = Bandit.start_link(plug: FakeDocker, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, url: "http://127.0.0.1:#{port}"}
  end

  test "19 containers in one tick; the hung stats call costs only its own container", %{url: url} do
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{containers: containers}, state} = Docker.collect(Docker.init_state(url: url))
    elapsed = System.monotonic_time(:millisecond) - started

    assert length(containers) == 19
    assert elapsed < 4_000, "tick took #{elapsed} ms"

    db = Enum.find(containers, &(&1.name == "blog-db-1"))
    assert db.stats_error =~ "timed out"
    assert db.mem_bytes == nil

    blog = Enum.find(containers, &(&1.name == "blog-blimp-blog-1"))
    assert blog.stats_error == nil
    assert blog.mem_bytes == 365_047_808 - 36_864
    assert blog.inspect.memory_limit == 1_610_612_736

    temper = Enum.find(containers, &(&1.name == "temper-link"))
    assert temper.inspect.status == "exited"

    refute inspect({containers, state}, limit: :infinity) =~ "never-leaves"
  end

  test "an unreachable Docker is a source error" do
    assert {:error, "connection refused", _} =
             Docker.collect(Docker.init_state(url: "http://127.0.0.1:1"))

    assert {:error, "DOCKER_URL is not set", _} = Docker.collect(Docker.init_state([]))
  end
end
