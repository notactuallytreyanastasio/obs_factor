defmodule ObsFactor.AccessLogTest do
  # Not async: one test runs the collector under its registered name and
  # writes the shared sources table.
  use ExUnit.Case, async: false

  alias ObsFactor.{AccessLog, Fixtures}

  @t0 1_795_071_600_000
  @no_meta %{skipped_bytes: 0, rotations: 0}

  defp line(host, uri, status \\ 200, duration \\ 0.001, opts \\ []),
    do: Fixtures.access_line(host, uri, status, duration, opts)

  defp append(path, lines),
    do: File.write!(path, Enum.map(lines, &[&1, "\n"]), [:append])

  defp state(path), do: AccessLog.init_state(path: path, nodes: Fixtures.topology().nodes)

  # A state that has done its first read of `path` at @t0.
  defp started(path) do
    assert {:ok, %{ready: false}, state} = AccessLog.collect(state(path), @t0)
    state
  end

  defp collect!(state, at_ms) do
    assert {:ok, data, state} = AccessLog.collect(state, at_ms)
    {data, state}
  end

  defp routes(data, id), do: data.nodes[id].routes

  describe "the contract's captured line" do
    @captured ~s({"level":"info","ts":1795071671.7652287,"logger":"http.log.access.log0","msg":"handled request","request":{"proto":"HTTP/1.1","method":"GET","host":"a.test","uri":"/arena/x"},"bytes_read":0,"duration":0.000152417,"size":5,"status":200,"country":"US","ua":"Mozilla/5.0 test"})

    test "parses" do
      assert AccessLog.parse(@captured) ==
               {:ok,
                %{
                  host: "a.test",
                  path: "/arena/x",
                  status: 200,
                  duration: 0.000152417,
                  ua: "Mozilla/5.0 test",
                  country: "US"
                }}
    end

    test "the fixture builder writes exactly that line" do
      assert line("a.test", "/arena/x", 200, 0.000152417) == @captured
      assert line("a.test", "/", 502) =~ ~s("level":"error")
    end

    test "anything that is not that object is bad" do
      for bad <- [
            "",
            "not json",
            "[1, 2]",
            ~s({"level":"info","msg":"something else"}),
            String.replace(@captured, ~s("status":200), ~s("status":"200")),
            String.replace(@captured, ~s("duration":0.000152417), ~s("duration":-1)),
            String.replace(@captured, ~s(,"ua":"Mozilla/5.0 test"), ""),
            String.replace(@captured, ~s("country":"US",), ""),
            String.replace(@captured, ~s("host":"a.test",), ""),
            binary_part(@captured, 0, 120)
          ] do
        assert AccessLog.parse(bad) == :bad, bad
      end
    end

    test "a query string, should one ever be written, is not kept" do
      assert {:ok, %{path: "/search"}} =
               @captured |> String.replace("/arena/x", "/search?q=secret") |> AccessLog.parse()
    end
  end

  describe "tailing" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      {:ok, path: Path.join(dir, "access.log")}
    end

    test "the first read starts at the end: history is not replayed", %{path: path} do
      append(path, List.duplicate(line("a.test", "/old"), 50))
      state = started(path)
      assert state.file.offset == File.stat!(path).size

      {data, _} = collect!(state, @t0 + 5_000)
      assert data.ready
      assert data.stats == %{lines: 0, bad_lines: 0, skipped_bytes: 0, rotations: 0, unrouted: 0}
      assert data.nodes == %{}
    end

    test "each read takes what was appended since the last", %{path: path} do
      append(path, [line("a.test", "/old")])
      state = started(path)

      append(path, [line("a.test", "/"), line("a.test", "/")])
      {data, state} = collect!(state, @t0 + 5_000)
      assert [%{path: "/", count: 2}] = routes(data, "blimp-blog")
      assert data.stats.lines == 2

      append(path, [line("a.test", "/about")])
      {data, state} = collect!(state, @t0 + 10_000)
      assert [%{path: "/", count: 2}, %{path: "/about", count: 1}] = routes(data, "blimp-blog")
      assert data.stats.lines == 3

      # Nothing new: nothing is read again.
      {data, _} = collect!(state, @t0 + 15_000)
      assert data.stats.lines == 3
    end

    test "a last line without its newline waits for the next read", %{path: path} do
      File.write!(path, "")
      state = started(path)

      whole = line("a.test", "/whole")
      {head, tail} = String.split_at(line("a.test", "/halves"), 100)
      File.write!(path, [whole, "\n", head], [:append])

      {data, state} = collect!(state, @t0 + 5_000)
      assert [%{path: "/whole", count: 1}] = routes(data, "blimp-blog")
      assert data.stats.lines == 1
      assert data.stats.bad_lines == 0

      File.write!(path, [tail, "\n"], [:append])
      {data, _} = collect!(state, @t0 + 10_000)
      assert Enum.map(routes(data, "blimp-blog"), & &1.path) == ["/halves", "/whole"]
      assert data.stats == %{lines: 2, bad_lines: 0, skipped_bytes: 0, rotations: 0, unrouted: 0}
    end

    test "rotation by rename: the new file is read from byte 0", %{path: path} do
      append(path, [line("a.test", "/old")])
      state = started(path)

      append(path, [line("a.test", "/before")])
      {_, state} = collect!(state, @t0 + 5_000)

      # Written after the last read and rotated away before the next: lost.
      append(path, [line("a.test", "/lost")])
      File.rename!(path, path <> ".1")
      append(path, [line("a.test", "/new-1"), line("a.test", "/new-2")])

      {data, state} = collect!(state, @t0 + 10_000)
      assert Enum.map(routes(data, "blimp-blog"), & &1.path) == ["/before", "/new-1", "/new-2"]
      assert data.stats.rotations == 1
      assert data.stats.lines == 3
      # The count of that read is known to be short: no rate from it.
      refute data.rates

      append(path, [line("a.test", "/new-3")])
      {data, _} = collect!(state, @t0 + 15_000)
      assert data.rates
      assert data.stats.rotations == 1
      assert data.stats.lines == 4
    end

    test "truncation: a file shorter than the offset is read from byte 0", %{path: path} do
      append(path, List.duplicate(line("a.test", "/old"), 10))
      state = started(path)
      inode = File.stat!(path).inode

      File.write!(path, [line("a.test", "/after-truncate"), "\n"])
      assert File.stat!(path).inode == inode

      {data, _} = collect!(state, @t0 + 5_000)
      assert [%{path: "/after-truncate", count: 1}] = routes(data, "blimp-blog")
      assert data.stats.rotations == 1
    end

    test "a carried half line is dropped with the file it came from", %{path: path} do
      File.write!(path, "")
      state = started(path)

      File.write!(path, binary_part(line("a.test", "/half"), 0, 100), [:append])
      {_, state} = collect!(state, @t0 + 5_000)
      assert state.carry != ""

      File.rename!(path, path <> ".1")
      append(path, [line("a.test", "/new")])

      {data, state} = collect!(state, @t0 + 10_000)
      assert [%{path: "/new", count: 1}] = routes(data, "blimp-blog")
      assert data.stats.bad_lines == 0
      assert state.carry == ""
    end

    test "more than 8 MiB in one tick: the oldest excess is skipped and counted", %{path: path} do
      File.write!(path, "")
      state = started(path)

      old = line("a.test", "/old")
      new = line("a.test", "/new")
      width = byte_size(old) + 1
      assert byte_size(new) + 1 == width

      cap = 8 * 1024 * 1024
      # 1000 lines too many, and the cut does not fall on a line boundary.
      total = div(cap, width) + 1000
      assert rem(cap, width) != 0
      append(path, List.duplicate(old, 1000) ++ List.duplicate(new, total - 1000))

      {data, state} = collect!(state, @t0 + 5_000)

      # Whole lines only: the line the cut fell in is skipped, not half read.
      assert data.stats.bad_lines == 0
      assert data.stats.lines == div(cap, width)
      assert data.stats.skipped_bytes == total * width - div(cap, width) * width
      assert data.stats.skipped_bytes + data.stats.lines * width == File.stat!(path).size
      assert [%{path: "/new", count: count}] = routes(data, "blimp-blog")
      assert count == data.stats.lines
      refute data.rates
      assert state.file.offset == File.stat!(path).size
    end

    test "exactly at a line boundary nothing more than the excess is skipped", %{path: path} do
      File.write!(path, "")
      state = started(path)

      cap = 8 * 1024 * 1024
      one = line("a.test", "/x")
      width = byte_size(one) + 1
      lines = div(cap, width)
      # Padding that is itself one (bad) line, so that the newest 8 MiB
      # starts exactly on a line.
      pad = String.duplicate("p", cap - lines * width - 1)

      File.write!(path, [String.duplicate("o", 499), "\n", pad, "\n"], [:append])
      append(path, List.duplicate(one, lines))

      {data, _} = collect!(state, @t0 + 5_000)
      assert data.stats.skipped_bytes == 500
      assert data.stats.lines == lines + 1
      assert data.stats.bad_lines == 1
    end

    test "bad lines are counted and nothing crashes", %{path: path} do
      File.write!(path, "")
      state = started(path)

      File.write!(
        path,
        [
          line("a.test", "/"),
          "\n",
          "garbage\n",
          "\n",
          <<0xFF, 0xFE, "\n">>,
          ~s({"level":"info","msg":"not a request"}\n),
          line("a.test", "/"),
          "\n"
        ],
        [:append]
      )

      {data, _} = collect!(state, @t0 + 5_000)
      assert data.stats.lines == 6
      assert data.stats.bad_lines == 4
      assert [%{path: "/", count: 2}] = routes(data, "blimp-blog")
    end

    test "a missing file fails the source with the reason, and reading resumes", %{path: path} do
      assert {:error, message, _} = AccessLog.collect(state(path), @t0)
      assert message == "cannot open #{path}: no such file or directory"

      append(path, [line("a.test", "/old")])
      state = started(path)
      append(path, [line("a.test", "/seen")])
      {_, state} = collect!(state, @t0 + 5_000)

      File.rm!(path)
      assert {:error, ^message, ^state} = AccessLog.collect(state, @t0 + 10_000)

      File.write!(path, "")
      append(path, [line("a.test", "/back")])
      {data, _} = collect!(state, @t0 + 15_000)
      assert "/back" in Enum.map(routes(data, "blimp-blog"), & &1.path)
    end

    test "a directory is not a log", %{tmp_dir: dir} do
      assert {:error, message, _} = AccessLog.collect(state(dir), @t0)
      assert message =~ "cannot open #{dir}: "
    end

    test "no path is named" do
      assert {:error, "ACCESS_LOG is not set", _} = AccessLog.collect(AccessLog.init_state([]))
    end

    test "under the collector: ok after one read, counts after two", %{path: path} do
      append(path, [line("a.test", "/old")])
      on_exit(fn -> :ets.delete(ObsFactor.Sources, :access) end)

      pid =
        start_supervised!(
          {ObsFactor.Collector,
           {AccessLog, interval_ms: 3_600_000, path: path, nodes: Fixtures.topology().nodes}}
        )

      _ = :sys.get_state(pid)
      assert %{ok: true, error: nil, data: %{ready: false}} = ObsFactor.Sources.get(:access)

      append(path, [line("bobbby.online", "/arena/x")])
      send(pid, :tick)
      _ = :sys.get_state(pid)

      assert %{ok: true, data: %{ready: true} = data} = ObsFactor.Sources.get(:access)
      assert [%{path: "/arena/x", count: 1}] = routes(data, "soldat")

      File.rm!(path)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :tick)
          _ = :sys.get_state(pid)
        end)

      assert log =~ "source access: cannot open"
      assert %{ok: false, data: nil, error: "cannot open " <> _} = ObsFactor.Sources.get(:access)
    end
  end

  describe "whose request it is" do
    setup do
      nodes = [
        %{id: "site", hosts: ["a.test", "www.a.test"], via: []},
        %{id: "arena", hosts: [], via: ["a.test/arena/*"]},
        %{id: "arena-api", hosts: [], via: ["a.test/arena/api/*"]},
        %{id: "exact", hosts: ["b.test"], via: ["a.test/exact"]},
        %{id: "wild", hosts: [], via: ["*.c.test/files/*/raw"]}
      ]

      {:ok, router: AccessLog.router(nodes)}
    end

    test "a via pattern wins over the host", %{router: r} do
      assert AccessLog.attribute(r, "a.test", "/arena/x") == {:via, "arena"}
      assert AccessLog.attribute(r, "a.test", "/") == {:host, "site"}
      assert AccessLog.attribute(r, "www.a.test", "/arena/x") == {:host, "site"}
    end

    test "the longest matching pattern wins", %{router: r} do
      assert AccessLog.attribute(r, "a.test", "/arena/api/score") == {:via, "arena-api"}
      assert AccessLog.attribute(r, "a.test", "/arena/apiary") == {:via, "arena"}
    end

    test "* matches anything, nothing and slashes; the rest is literal", %{router: r} do
      assert AccessLog.attribute(r, "a.test", "/arena/") == {:via, "arena"}
      assert AccessLog.attribute(r, "a.test", "/arena/a/b/c") == {:via, "arena"}
      # No star, no prefix match.
      assert AccessLog.attribute(r, "a.test", "/arena") == {:host, "site"}
      assert AccessLog.attribute(r, "a.test", "/exact") == {:via, "exact"}
      assert AccessLog.attribute(r, "a.test", "/exact/more") == {:host, "site"}
      assert AccessLog.attribute(r, "x.c.test", "/files/a/b/raw") == {:via, "wild"}
      assert AccessLog.attribute(r, "x.c.test", "/files/a/b/raw.txt") == :unrouted
      # A dot in a pattern is a dot.
      assert AccessLog.attribute(r, "aXtest", "/arena/x") == :unrouted
    end

    test "hosts compare without case", %{router: r} do
      assert AccessLog.attribute(r, "A.Test", "/arena/x") == {:via, "arena"}
      assert AccessLog.attribute(r, "B.TEST", "/") == {:host, "exact"}
      # Paths do not.
      assert AccessLog.attribute(r, "a.test", "/Arena/x") == {:host, "site"}
    end

    test "nobody's host is unrouted", %{router: r} do
      assert AccessLog.attribute(r, "nobody.test", "/") == :unrouted
      assert AccessLog.attribute(r, "", "/") == :unrouted
    end

    test "unrouted requests are counted and still say who asked" do
      lines = [line("nobody.test", "/", 200, 0.001, ua: "curl/8.5.0"), line("a.test", "/")]
      {data, _} = AccessLog.step(Fixtures.access_state(), lines, @no_meta, Fixtures.now_ms())

      assert data.stats.unrouted == 1
      assert Map.keys(data.nodes) == ["blimp-blog"]
      assert data.clients.classes == %{browser: 1, bot: 0, tool: 1, other: 0}
    end

    test "via rates count only the path routes, by class, over the tick" do
      data = Fixtures.access()

      assert data.rates
      assert Map.keys(data.via) == ["soldat"]
      assert data.via["soldat"].rps == 2.0

      assert data.via["soldat"].codes ==
               %{"2xx" => 1.8, "3xx" => 0.0, "4xx" => 0.0, "5xx" => 0.2, "other" => 0.0}
    end

    test "status classes: 101 and Caddy's 0 are other" do
      lines =
        for status <- [101, 0, 200, 301, 404, 503, 600],
            do: line("bobbby.online", "/arena/", status)

      {data, _} = AccessLog.step(Fixtures.access_state(), lines, @no_meta, Fixtures.now_ms())

      assert data.via["soldat"].codes ==
               %{"2xx" => 0.2, "3xx" => 0.2, "4xx" => 0.2, "5xx" => 0.2, "other" => 0.6}

      assert [%{path: "/arena/", count: 7, errors: 1}] = routes(data, "soldat")
    end
  end

  describe "the window and its bounds" do
    defp step(state, lines, at_ms), do: AccessLog.step(state, lines, @no_meta, at_ms)

    test "tables cover the last 300 s; rates only the last tick" do
      now = Fixtures.now_ms()
      state = Fixtures.access_state()

      {data, state} = step(state, List.duplicate(line("bobbby.online", "/arena/"), 10), now)
      assert [%{count: 10, rps: 0.033}] = routes(data, "soldat")
      assert data.via["soldat"].rps == 2.0

      {data, state} = step(state, [line("bobbby.online", "/arena/")], now + 5_000)
      assert [%{count: 11, rps: 0.037}] = routes(data, "soldat")
      assert data.via["soldat"].rps == 0.2
      assert data.stats.lines == 11

      # 299 s after the first tick it is still in the window.
      {data, state} = step(state, [], now + 299_000)
      assert [%{count: 11}] = routes(data, "soldat")
      assert data.via == %{}

      # At 300 s it is out; the second tick stays for 5 s more.
      {data, state} = step(state, [], now + 300_000)
      assert [%{count: 1}] = routes(data, "soldat")
      assert data.stats.lines == 1

      {data, state} = step(state, [], now + 305_000)
      assert data.nodes == %{}
      assert data.stats.lines == 0
      assert data.clients.classes == %{browser: 0, bot: 0, tool: 0, other: 0}
      assert data.clients.countries == []
      # Only the reads of the last 300 s are held: three of the five.
      assert length(state.window) == 3
    end

    test "at most 8 routes, busiest first, ties by path; errors are 5xx" do
      lines =
        for n <- 1..12, _ <- 1..n do
          line(
            "a.test",
            "/p#{String.pad_leading("#{n}", 2, "0")}",
            if(n == 12, do: 500, else: 404)
          )
        end

      lines = lines ++ List.duplicate(line("a.test", "/also-11"), 11)
      {data, _} = step(Fixtures.access_state(), lines, Fixtures.now_ms())

      rows = routes(data, "blimp-blog")

      assert Enum.map(rows, &{&1.path, &1.count, &1.errors}) == [
               {"/p12", 12, 12},
               {"/also-11", 11, 0},
               {"/p11", 11, 0},
               {"/p10", 10, 0},
               {"/p09", 9, 0},
               {"/p08", 8, 0},
               {"/p07", 7, 0},
               {"/p06", 6, 0}
             ]

      # Latency is over every request, not only the rows shown.
      assert data.nodes["blimp-blog"].latency.count == 89
    end

    test "paths are cut at 80 characters" do
      long = "/" <> String.duplicate("a", 120)

      lines = [
        line("a.test", long <> "x"),
        line("a.test", long <> "y"),
        line("a.test", "/é" <> long)
      ]

      {data, _} = step(Fixtures.access_state(), lines, Fixtures.now_ms())

      assert [%{path: cut, count: 2}, %{path: accented, count: 1}] = routes(data, "blimp-blog")
      assert cut == String.slice(long, 0, 80)
      assert String.length(accented) == 80
      assert String.starts_with?(accented, "/é/")
    end

    test "a node keeps 200 distinct paths in one read; the rest are (other)" do
      # /hot twice, 199 more paths once each, then 50 paths that find no room.
      lines =
        [line("a.test", "/hot", 200, 0.001), line("a.test", "/hot", 200, 0.001)] ++
          for(n <- 1..199, do: line("a.test", "/kept-#{n}", 200, 0.001)) ++
          for(n <- 1..50, do: line("a.test", "/late-#{n}", 503, 0.5)) ++
          [line("a.test", "/kept-7", 200, 0.001), line("bobbby.online", "/arena/late-1")]

      state = Fixtures.access_state()
      {data, state} = step(state, lines, Fixtures.now_ms())

      rows = routes(data, "blimp-blog")
      assert length(rows) == 8

      assert [%{path: "(other)", count: 50, errors: 50, rps: 0.167, p95_ms: p95}, hot, kept | _] =
               rows

      assert_in_delta p95, 500.0, 500.0 * 0.045
      assert %{path: "/hot", count: 2} = hot
      # A path that already has its row is still counted there.
      assert %{path: "/kept-7", count: 2} = kept
      assert data.nodes["blimp-blog"].latency.count == 252

      # The bound is per node: another node's paths are its own.
      assert [%{path: "/arena/late-1", count: 1}] = routes(data, "soldat")

      [{_, bucket}] = state.window
      assert map_size(bucket.nodes["blimp-blog"].paths) == 201
    end

    test "over the window a node keeps its 200 busiest paths; the rest are (other)" do
      now = Fixtures.now_ms()
      state = Fixtures.access_state()

      # 150 paths seen once, then 150 others seen twice: 300 distinct in the
      # window, none folded within a read.
      once = for n <- 1..150, do: line("a.test", "/once-#{n}")
      twice = for n <- 1..150, _ <- 1..2, do: line("a.test", "/twice-#{n}")

      {data, state} = step(state, once, now)
      refute Enum.any?(routes(data, "blimp-blog"), &(&1.path == "(other)"))

      {data, state} = step(state, twice, now + 5_000)

      # Kept: the 150 seen twice and 50 of those seen once. Folded: 100.
      assert [%{path: "(other)", count: 100} | rest] = routes(data, "blimp-blog")
      assert Enum.all?(rest, &(&1.count == 2 and String.starts_with?(&1.path, "/twice-")))
      assert data.nodes["blimp-blog"].latency.count == 450

      # When the first read leaves the window, so does the fold.
      {data, _} = step(state, [], now + 300_000)
      refute Enum.any?(routes(data, "blimp-blog"), &(&1.path == "(other)"))
      assert data.nodes["blimp-blog"].latency.count == 300
    end
  end

  describe "who is asking" do
    test "User-Agent classes, as the contract lists them" do
      for {ua, class} <- [
            {"obs-factor-traffic/1.0", :tool},
            {"obs-factor-traffic", :tool},
            {"curl/8.5.0", :tool},
            {"Wget/1.21.4", :tool},
            # A tool that names itself a bot is still a tool: the prefix is checked first.
            {"curl/8.5.0 (somebot)", :tool},
            {"", :bot},
            {"Googlebot/2.1 (+http://www.google.com/bot.html)", :bot},
            {"Mozilla/5.0 (compatible; bingbot/2.0)", :bot},
            {"Mozilla/5.0 (compatible; Yahoo! Slurp)", :bot},
            {"Baiduspider", :bot},
            {"Mozilla/5.0 AppleWebKit CRAWLer", :bot},
            {"Mozilla/5.0 (X11; Linux x86_64) Firefox/131.0", :browser},
            {"Mozilla/5.0 test", :browser},
            # Prefixes are prefixes, in their own case.
            {"mozilla/5.0", :other},
            {"wget/1.0", :other},
            {"libcurl/8", :other},
            {"python-requests/2.32", :other},
            {"Go-http-client/2.0", :other}
          ] do
        assert AccessLog.client_class(ua) == class, ua
      end
    end

    test "classes and at most 8 countries over the window, an absent country as ??" do
      countries =
        ~w(US US US US DE DE DE FR FR GB JP BR IN CA) ++ ["", "", "us", "not a country", "T1"]

      uas = ["Mozilla/5.0 test", "", "curl/8.5.0", "python-requests/2.32"]

      lines =
        for {country, i} <- Enum.with_index(countries) do
          line("a.test", "/", 200, 0.001, country: country, ua: Enum.at(uas, rem(i, 4)))
        end

      {data, _} = step(Fixtures.access_state(), lines, Fixtures.now_ms())

      assert data.clients == %{
               classes: %{browser: 5, bot: 5, tool: 5, other: 4},
               countries: [
                 %{code: "US", count: 5},
                 %{code: "??", count: 3},
                 %{code: "DE", count: 3},
                 %{code: "FR", count: 2},
                 %{code: "BR", count: 1},
                 %{code: "CA", count: 1},
                 %{code: "GB", count: 1},
                 %{code: "IN", count: 1}
               ],
               window_s: 300
             }
    end
  end

  describe "percentiles" do
    test "a bucket reports within 4.4 % of any duration from 1 µs to an hour" do
      for exp <- -600..355 do
        seconds = :math.pow(10, exp / 100)
        reported = seconds |> AccessLog.duration_bucket() |> AccessLog.bucket_ms()
        assert_in_delta reported / (seconds * 1000), 1.0, 0.0443, "#{seconds} s"
      end
    end

    test "below 1 µs and above 71 minutes the ends of the scale are reported" do
      assert AccessLog.duration_bucket(0) == 0
      assert AccessLog.duration_bucket(1.0e-9) == 0
      assert AccessLog.duration_bucket(1.0e-6) == 0
      assert AccessLog.duration_bucket(86_400) == AccessLog.duration_bucket(1.0e9)
      assert_in_delta AccessLog.bucket_ms(AccessLog.duration_bucket(86_400)), 4_485_000, 1_000
    end

    test "nearest rank over the histogram" do
      hist = Enum.frequencies(for ms <- 1..100, do: AccessLog.duration_bucket(ms / 1000))

      for {p, exact} <- [{0.5, 50}, {0.95, 95}, {0.99, 99}, {1.0, 100}, {0.0, 1}, {0.001, 1}] do
        assert_in_delta AccessLog.percentile(hist, p), exact, exact * 0.0443, "p#{p}"
      end

      assert AccessLog.percentile(%{}, 0.95) == nil
      assert AccessLog.percentile(%{40 => 1}, 0.5) == AccessLog.bucket_ms(40)
    end

    test "a node's latency and a route's p95 over its requests" do
      # 100 requests: 1..100 ms, and one slow path that is its own row.
      lines =
        for(ms <- 1..99, do: line("a.test", "/", 200, ms / 1000)) ++
          [line("a.test", "/slow", 200, 0.1)]

      {data, _} = step(Fixtures.access_state(), lines, Fixtures.now_ms())

      assert %{count: 100, p50_ms: p50, p95_ms: p95, p99_ms: p99} =
               data.nodes["blimp-blog"].latency

      assert_in_delta p50, 50, 50 * 0.0443
      assert_in_delta p95, 95, 95 * 0.0443
      assert_in_delta p99, 99, 99 * 0.0443

      assert [%{path: "/", count: 99, p95_ms: root}, %{path: "/slow", count: 1, p95_ms: slow}] =
               routes(data, "blimp-blog")

      # ceil(0.95 * 99) = 95th of 1..99 ms.
      assert_in_delta root, 95, 95 * 0.0443
      assert_in_delta slow, 100, 100 * 0.0443
    end
  end
end
