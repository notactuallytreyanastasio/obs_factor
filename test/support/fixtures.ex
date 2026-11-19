defmodule ObsFactor.Fixtures do
  @moduledoc """
  Readings built from the real payloads in test/fixtures/box/capture.json and
  the real Caddy page in test/fixtures/caddy_2.10.2_metrics.txt.

  The capture has inspect bodies for three containers only. For the other
  sixteen, `docker/0` derives the inspect fields from the container list
  entry (running per the list, no restarts, no limit); this is labelled here
  because it is the one place test data is filled in rather than captured.
  """

  alias ObsFactor.Docker
  alias ObsFactor.Docker.Parse

  @capture Path.expand("../fixtures/box/capture.json", __DIR__)
  @caddy Path.expand("../fixtures/caddy_2.10.2_metrics.txt", __DIR__)

  def capture, do: @capture |> File.read!() |> Jason.decode!()
  def caddy_text, do: File.read!(@caddy)

  def now, do: ~U[2026-11-18 22:34:52Z]
  def now_ms, do: DateTime.to_unix(now(), :millisecond)

  @doc "Docker collector data after the two real stats samples."
  def docker do
    cap = capture()
    entries = Enum.map(cap["containers"], &Parse.list_entry/1)

    inspects =
      Map.new(entries, fn e ->
        case cap["inspect"][e.name] do
          nil -> {e.id, {:ok, derived_inspect(e)}}
          body -> {e.id, Parse.inspect_body(Jason.encode!(body))}
        end
      end)

    details = fn stats_key ->
      Enum.map(entries, fn e ->
        stats =
          case cap[stats_key][e.name] do
            nil -> if e.state == "running", do: {:error, "not in capture"}, else: :not_running
            body -> {:ok, Parse.stats(body)}
          end

        %{entry: e, inspect: inspects[e.id], stats: stats}
      end)
    end

    state = %{url: "http://docker", samples: %{}, restarts: %{}}
    {_, samples, restarts} = Docker.assemble(details.("stats_a"), state, now_ms() - 5_000)

    {containers, _, _} =
      Docker.assemble(
        details.("stats_b"),
        %{state | samples: samples, restarts: restarts},
        now_ms()
      )

    # Containers the capture has no stats for: no stats error either, just unknown.
    containers =
      Enum.map(containers, fn c ->
        if c.stats_error == "not in capture", do: %{c | stats_error: nil}, else: c
      end)

    %{containers: containers}
  end

  defp derived_inspect(e) do
    running = e.state == "running"

    %{
      status: e.state,
      running: running,
      restarting: false,
      oom_killed: false,
      exit_code: 0,
      started_at: ~U[2026-11-01 00:00:00Z],
      finished_at: nil,
      health: if(String.contains?(e.status_text, "(healthy)"), do: "healthy", else: nil),
      restart_count: 0,
      restart_policy: "always",
      memory_limit: nil
    }
  end

  @doc "Host collector data from the two /proc readings and statvfs."
  def host do
    cap = capture()
    a = ObsFactor.Host.parse_stat(cap["proc_a"]["stat"])
    b = ObsFactor.Host.parse_stat(cap["proc_b"]["stat"])
    s = cap["statvfs_root"]

    %{
      cores: b.cores,
      cpu_used_cores: ObsFactor.Host.cpu_used(a, b),
      load1: ObsFactor.Host.parse_loadavg(cap["proc_b"]["loadavg"])
    }
    |> Map.merge(ObsFactor.Host.parse_meminfo(cap["proc_b"]["meminfo"]))
    |> Map.merge(
      ObsFactor.Host.disk_usage(%{
        f_frsize: s["f_frsize"],
        f_blocks: s["f_blocks"],
        f_bfree: s["f_bfree"],
        f_bavail: s["f_bavail"]
      })
    )
  end

  @doc """
  pg_stat_database rows as the capture has them (psql -A -F, output). The
  first four columns are datname, pg_database_size, numbackends, xact_commit;
  the rest are not used.
  """
  def pg_rows do
    capture()["pg_stat_database"]
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, size, backends, commits | _] = String.split(line, ",")
      [name, String.to_integer(size), String.to_integer(backends), String.to_integer(commits)]
    end)
  end

  @doc "Postgres data: one reading, then the same rows 5 s later with commits bumped."
  def postgres(connections \\ 96) do
    max = capture()["pg_max_connections"] |> String.to_integer()
    a = ObsFactor.Postgres.reading(pg_rows(), max, connections, now_ms() - 5_000)

    rows_b =
      Enum.map(pg_rows(), fn [n, s, b, c] ->
        [n, s, b, if(n == "blog_prod", do: c + 50, else: c)]
      end)

    b = ObsFactor.Postgres.reading(rows_b, max, connections, now_ms())
    ObsFactor.Postgres.rates(a, b)
  end

  @doc "Caddy data: the real page, and the same page with a.test's counters advanced."
  def caddy do
    text = caddy_text()
    a = ObsFactor.Caddy.reading(text, now_ms() - 5_000)

    b_text =
      text
      |> String.replace(
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 6),
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 16)
      )

    b = ObsFactor.Caddy.reading(b_text, now_ms())
    ObsFactor.Caddy.rates(a, b)
  end

  def ok(data), do: %{ok: true, at: now(), error: nil, data: data}
  def failed(error), do: %{ok: false, at: nil, error: error, data: nil}

  def sources(overrides \\ %{}) do
    Map.merge(
      %{
        docker: ok(docker()),
        caddy: ok(caddy()),
        postgres: ok(postgres()),
        host: ok(host()),
        probes: ok(%{"blimp-blog" => %{ok: true, code: 200, ms: 12, error: nil}}),
        sites:
          ok(%{
            "deciduous" => %{bytes: 2_048_000, files: 12, newest_mtime: ~U[2026-11-10 12:00:00Z]}
          })
      },
      overrides
    )
  end

  def topology, do: ObsFactor.Topology.load!(Path.expand("topology.exs", __DIR__))
end
