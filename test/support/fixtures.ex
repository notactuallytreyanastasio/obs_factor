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

  @doc """
  Caddy data: the real page, and 5 s later the same page with a.test's
  series advanced by ten requests (eight 200s, two 404s, 80 ms in all,
  1000 request bytes, 60000 response bytes) and two requests in flight.
  b.test does not move.
  """
  def caddy do
    text = caddy_text()
    a = ObsFactor.Caddy.reading(text, now_ms() - 5_000)

    a_test = ~s(handler="subroute",host="a.test",server="srv0"})
    a_200 = ~s({code="200",handler="subroute",host="a.test",method="GET",server="srv0"})
    a_404 = ~s({code="404",handler="subroute",host="a.test",method="GET",server="srv0"})

    b_text =
      text
      |> advance("caddy_http_requests_total{" <> a_test, "6", "16")
      |> advance("caddy_http_request_duration_seconds_count" <> a_200, "5", "13")
      |> advance("caddy_http_request_duration_seconds_count" <> a_404, "1", "3")
      |> advance("caddy_http_request_duration_seconds_sum" <> a_200, "0.00778213", "0.08778213")
      |> advance("caddy_http_request_size_bytes_sum" <> a_200, "235", "1235")
      |> advance("caddy_http_response_size_bytes_sum" <> a_200, "15", "60015")
      |> advance("caddy_http_requests_in_flight{" <> a_test, "0", "2")

    b = ObsFactor.Caddy.reading(b_text, now_ms())
    ObsFactor.Caddy.rates(a, b)
  end

  # Rewrites one series line of the page; a line that is not there is an error.
  defp advance(text, series, from, to) do
    line = "#{series} #{from}\n"

    unless String.contains?(text, line),
      do: raise(ArgumentError, "caddy fixture has no line #{inspect(line)}")

    String.replace(text, line, "#{series} #{to}\n")
  end

  @doc """
  One access log line exactly as Caddy 2.10.2 writes it with the `(access)`
  snippet (the line captured in docs/contract.md), with these fields set.
  A 5xx line has `"level":"error"`, as Caddy writes it.
  """
  def access_line(host, uri, status, duration, opts \\ []) do
    level = if status >= 500, do: "error", else: "info"
    ua = Keyword.get(opts, :ua, "Mozilla/5.0 test")
    country = Keyword.get(opts, :country, "US")
    # Decimal, as Go writes it (0.000152417), not 1.52417e-4.
    seconds = :erlang.float_to_binary(duration / 1, [{:decimals, 9}, :compact])

    ~s({"level":"#{level}","ts":1795071671.7652287,"logger":"http.log.access.log0","msg":"handled request","request":{"proto":"HTTP/1.1","method":"GET","host":"#{host}","uri":"#{uri}"},"bytes_read":0,"duration":#{seconds},"size":5,"status":#{status},"country":"#{country}","ua":"#{ua}"})
  end

  @doc """
  The lines of one 5 s tick: ten requests on the arena's path route (one a
  502), five for a.test (one a 404), one for a host nobody lists, and one
  line that is not an access line.
  """
  def access_lines do
    List.duplicate(access_line("bobbby.online", "/arena/", 200, 0.002), 6) ++
      List.duplicate(access_line("bobbby.online", "/arena/assets/app.js", 200, 0.0004), 3) ++
      [access_line("bobbby.online", "/arena/x", 502, 0.25, ua: "curl/8.5.0", country: "")] ++
      List.duplicate(access_line("a.test", "/", 200, 0.008, country: "DE"), 4) ++
      [
        access_line("a.test", "/posts/1", 404, 0.001, ua: "Googlebot/2.1", country: "DE"),
        access_line("bobbby.online", "/", 200, 0.003, ua: "obs-factor-traffic/1"),
        "not json"
      ]
  end

  @doc "The access collector's state after its first read, 5 s before `now/0`."
  def access_state do
    %{
      ObsFactor.AccessLog.init_state(path: "unused", nodes: topology().nodes)
      | prev_at: now_ms() - 5_000
    }
  end

  @doc "Access log data: `access_lines/0` read 5 s after the first read."
  def access do
    {data, _state} =
      ObsFactor.AccessLog.step(
        access_state(),
        access_lines(),
        %{skipped_bytes: 0, rotations: 0},
        now_ms()
      )

    data
  end

  @report Path.expand("../fixtures/report_blog.json", __DIR__)

  @doc "The example report of docs/contract.md, as the reporter serves it."
  def report_body, do: File.read!(@report)
  def report_doc, do: Jason.decode!(report_body())

  @doc """
  The same process 5 s later: 256000 reductions and 5000 bytes out more, six
  more `GET /post/:slug` (134.4 ms in all), fifty more queries (25 ms in
  all), one more outbound call that failed after 2 s. Nobody liked anything.
  """
  def report_doc_later do
    report_doc()
    |> update_in(["runtime", "uptime_s"], &(&1 + 5))
    |> update_in(["runtime", "counters", "reductions"], &(&1 + 256_000))
    |> update_in(["runtime", "counters", "io.out_bytes"], &(&1 + 5_000))
    |> update_in(["streams"], fn streams ->
      Enum.map(streams, fn s ->
        {count, errors, us} =
          case s["name"] do
            "GET /post/:slug" -> {6, 0, 134_400}
            "Blog.Repo" -> {50, 0, 25_000}
            "api.deepseek.com" -> {1, 1, 2_000_000}
            "BlogWeb.PostLive#like" -> {0, 0, 0}
          end

        s
        |> Map.update!("count", &(&1 + count))
        |> Map.update!("errors", &(&1 + errors))
        |> Map.update!("duration_us", &(&1 + us))
      end)
    end)
  end

  @doc "Reports data: the app's report read twice, 5 s apart."
  def reports do
    {:ok, first} = ObsFactor.Reports.validate(report_doc())
    {:ok, second} = ObsFactor.Reports.validate(report_doc_later())

    {_, state} =
      ObsFactor.Reports.step(ObsFactor.Reports.new_node(), {:ok, first}, now_ms() - 5_000)

    {data, _} = ObsFactor.Reports.step(state, {:ok, second}, now_ms())
    %{"app" => data}
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
          }),
        access: ok(access()),
        reports: ok(reports())
      },
      overrides
    )
  end

  def topology, do: ObsFactor.Topology.load!(Path.expand("topology.exs", __DIR__))
end
