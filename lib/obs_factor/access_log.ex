defmodule ObsFactor.AccessLog do
  @moduledoc """
  Access log collector: tails Caddy's JSON access log at `ACCESS_LOG` and
  counts what the Prometheus counters cannot say: requests per path route,
  the busiest paths of each node, latency percentiles and who is asking
  (docs/contract.md, "Access log").

  ## Reading

  The first read only notes the end of the file: history is not replayed.
  Every later read takes what was appended since. A different inode, or a
  file shorter than the offset, is a rotation: reading restarts at byte 0 and
  whatever was unread in the old file is lost (counted in `rotations`). A
  last line without a newline is carried to the next read. When more than
  8 MiB is waiting, only the newest 8 MiB is read, from the first line that
  starts inside it; everything before that is `skipped_bytes`. A carried
  line that grows past 1 MiB without a newline is dropped into
  `skipped_bytes` as well. A line that is not the object the contract shows
  is counted in `bad_lines`.

  Two things this cannot see: a file truncated and already grown back past
  the old offset between two reads, and a file deleted and recreated on the
  same inode at a size at or past the old offset. Both read on from the old
  offset.

  No line is kept or logged. What stays in memory is one bucket of counts
  per read for the last 300 s.

  ## Bounds

  A bucket holds at most 200 distinct paths per node (the first 200 seen in
  that read); further paths are counted under `"(other)"`. Summed over the
  window a node again keeps at most 200 paths, the busiest, and the rest are
  folded into `"(other)"`. Paths are cut at 80 characters. Countries are two
  letters or digits, upper-cased; anything else (Caddy writes `""` when
  Cloudflare sent none) is `"??"`.

  ## Percentiles

  Durations are counted in fixed log-scale buckets, eight per octave: bucket
  `i` holds durations in `[2^(i/8), 2^((i+1)/8))` microseconds, from 1 µs
  (bucket 0, which also takes anything shorter) to 2^32 µs, about 71 minutes
  (the last bucket, which also takes anything longer). A percentile is the
  nearest-rank bucket's geometric midpoint, so between 1 µs and 71 minutes it
  is within a factor of 2^(1/16), ±4.4 %, of the sample an exact
  nearest-rank percentile would have returned. Nothing is sampled or
  dropped: `count` is exact.

  ## Rates

  `via` rates are the requests of this read divided by the time since the
  previous successful read. On a read that saw a rotation or skipped bytes
  the count is known to be short, so the rates are nil for that read rather
  than too low.
  """

  @behaviour ObsFactor.Collector

  @window_ms 300_000
  @cap 8 * 1024 * 1024
  @max_line 1024 * 1024
  @max_paths 200
  @path_chars 80
  @top_routes 8
  @top_countries 8
  @other "(other)"
  @per_octave 8
  @max_bucket 32 * @per_octave
  @classes ["2xx", "3xx", "4xx", "5xx", "other"]
  @client_classes [:browser, :bot, :tool, :other]

  @impl true
  def name, do: :access

  @doc "`opts`: `:path` (the file) and `:nodes` (the topology's nodes)."
  @impl true
  def init_state(opts) do
    %{
      path: Keyword.get(opts, :path),
      router: router(Keyword.get(opts, :nodes, [])),
      # %{inode, offset} once the file has been read.
      file: nil,
      carry: "",
      prev_at: nil,
      window: []
    }
  end

  @impl true
  def collect(state), do: collect(state, System.system_time(:millisecond))

  @doc "`collect/1` at a given time."
  def collect(%{path: nil} = state, _now_ms), do: {:error, "ACCESS_LOG is not set", state}

  def collect(state, now_ms) do
    case read(state) do
      {:first, state} ->
        {:ok, %{ready: false}, %{state | prev_at: now_ms}}

      {:ok, lines, meta, state} ->
        {data, state} = step(state, lines, meta, now_ms)
        {:ok, data, state}

      {:error, message} ->
        {:error, message, state}
    end
  end

  ## Tailing

  @doc """
  Reads what was appended since the last read. `{:first, state}` on the
  first read (positioned at the end, nothing read),
  `{:ok, lines, %{skipped_bytes, rotations}, state}` after, or
  `{:error, message}`.
  """
  def read(%{path: path} = state) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          read_open(fd, state)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, "cannot open #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp read_open(fd, state) do
    case :file.read_file_info(fd) do
      {:ok, info} ->
        %File.Stat{size: size, inode: inode, type: type} = File.Stat.from_record(info)

        case {type, state.file} do
          {type, _} when type != :regular ->
            {:error, "#{state.path} is not a regular file (#{type})"}

          {_, nil} ->
            {:first, %{state | file: %{inode: inode, offset: size}, carry: ""}}

          {_, %{inode: ^inode, offset: offset}} when size >= offset ->
            take(fd, state, offset, size, state.carry, 0)

          {_, _rotated} ->
            take(fd, state, 0, size, "", 1)
        end

      {:error, reason} ->
        {:error, "cannot stat #{state.path}: #{:file.format_error(reason)}"}
    end
  end

  defp take(fd, state, from, size, carry, rotations) do
    result =
      if size - from > @cap do
        start = size - @cap
        # One byte early: only a newline there says `start` begins a line.
        with {:ok, <<before, data::binary>>} <- pread(fd, start - 1, @cap + 1) do
          {data, dropped} = if before == ?\n, do: {data, 0}, else: from_next_line(data)
          at_end = start + dropped + byte_size(data)
          {:ok, data, at_end, start - from + dropped + byte_size(carry)}
        end
      else
        with {:ok, data} <- pread(fd, from, size - from) do
          {:ok, carry <> data, from + byte_size(data), 0}
        end
      end

    case result do
      {:ok, buffer, offset, skipped} ->
        {lines, [rest]} = buffer |> :binary.split("\n", [:global]) |> Enum.split(-1)

        {carry, skipped} =
          if byte_size(rest) > @max_line,
            do: {"", skipped + byte_size(rest)},
            else: {rest, skipped}

        {:ok, lines, %{skipped_bytes: skipped, rotations: rotations},
         %{state | file: %{inode: inode(fd), offset: offset}, carry: carry}}

      {:error, reason} ->
        {:error, "cannot read #{state.path}: #{:file.format_error(reason)}"}
    end
  end

  defp inode(fd) do
    {:ok, info} = :file.read_file_info(fd)
    File.Stat.from_record(info).inode
  end

  defp pread(_fd, _at, 0), do: {:ok, ""}

  defp pread(fd, at, length) do
    case :file.pread(fd, at, length) do
      {:ok, data} -> {:ok, data}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  # Drops the tail of a line whose head was skipped.
  defp from_next_line(data) do
    case :binary.match(data, "\n") do
      {at, 1} -> {binary_part(data, at + 1, byte_size(data) - at - 1), at + 1}
      :nomatch -> {"", byte_size(data)}
    end
  end

  ## Whose request it is

  @doc """
  What attribution needs from the topology's nodes: every `via` pattern,
  longest first, and the node of every host.
  """
  def router(nodes) do
    vias =
      for n <- nodes, pattern <- Map.get(n, :via, []) do
        {pattern, n.id}
      end
      |> Enum.sort_by(fn {pattern, id} -> {-String.length(pattern), pattern, id} end)
      |> Enum.map(fn {pattern, id} -> {compile(pattern), id} end)

    hosts =
      for n <- nodes, host <- Map.get(n, :hosts, []), into: %{} do
        {String.downcase(host), n.id}
      end

    %{vias: vias, hosts: hosts}
  end

  # `*` matches anything, slashes too; everything else is literal. The host
  # part is matched in lower case, as Caddy's metrics report hosts.
  defp compile(pattern) do
    {host, path} =
      case String.split(pattern, "/", parts: 2) do
        [host, path] -> {host, "/" <> path}
        [host] -> {host, ""}
      end

    source =
      (String.downcase(host) <> path)
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.compile!("\\A" <> source <> "\\z", "s")
  end

  @doc """
  `{:via, node_id}` when a `via` pattern matches `host <> path` (the longest
  pattern wins), else `{:host, node_id}` when a node lists the host, else
  `:unrouted`.
  """
  def attribute(router, host, path) do
    host = String.downcase(host)
    subject = host <> path

    case Enum.find(router.vias, fn {regex, _} -> Regex.match?(regex, subject) end) do
      {_, id} ->
        {:via, id}

      nil ->
        case router.hosts do
          %{^host => id} -> {:host, id}
          _ -> :unrouted
        end
    end
  end

  ## Lines

  @doc """
  One line as `{:ok, %{host, path, status, duration, ua, country}}`, or
  `:bad`. `path` is the uri without a query string (Caddy already strips it;
  a line that still has one loses it here), whole: it is cut when counted.
  """
  def parse(line) do
    case Jason.decode(line) do
      {:ok,
       %{
         "request" => %{"host" => host, "uri" => uri},
         "status" => status,
         "duration" => duration,
         "ua" => ua,
         "country" => country
       }}
      when is_binary(host) and is_binary(uri) and is_integer(status) and is_number(duration) and
             duration >= 0 and is_binary(ua) and is_binary(country) ->
        [path | _] = String.split(uri, "?", parts: 2)

        {:ok,
         %{host: host, path: path, status: status, duration: duration, ua: ua, country: country}}

      _ ->
        :bad
    end
  end

  @doc """
  `:tool` for a User-Agent starting `obs-factor-traffic`, `curl/` or `Wget/`;
  `:bot` for one containing `bot`, `spider`, `crawl` or `slurp` in any case,
  or empty; `:browser` for one starting `Mozilla/` that is neither; else
  `:other`.
  """
  def client_class(ua) do
    cond do
      String.starts_with?(ua, ["obs-factor-traffic", "curl/", "Wget/"]) -> :tool
      ua == "" or String.contains?(String.downcase(ua), ~w(bot spider crawl slurp)) -> :bot
      String.starts_with?(ua, "Mozilla/") -> :browser
      true -> :other
    end
  end

  defp status_class(status) when status in 200..599, do: "#{div(status, 100)}xx"
  defp status_class(_), do: "other"

  defp country(code) do
    if Regex.match?(~r/\A[A-Za-z0-9]{2}\z/, code), do: String.upcase(code), else: "??"
  end

  ## Counting

  @doc "The counts of one read's lines."
  def bucket(lines, router) do
    empty = %{lines: 0, bad_lines: 0, unrouted: 0, clients: %{}, countries: %{}, nodes: %{}}
    Enum.reduce(lines, empty, &count(&1, &2, router))
  end

  defp count(line, b, router) do
    b = %{b | lines: b.lines + 1}

    case parse(line) do
      :bad ->
        %{b | bad_lines: b.bad_lines + 1}

      {:ok, r} ->
        b = %{
          b
          | clients: bump(b.clients, client_class(r.ua)),
            countries: bump(b.countries, country(r.country))
        }

        case attribute(router, r.host, r.path) do
          :unrouted -> %{b | unrouted: b.unrouted + 1}
          {how, id} -> %{b | nodes: Map.update(b.nodes, id, node(nil, r, how), &node(&1, r, how))}
        end
    end
  end

  defp node(nil, r, how), do: node(%{paths: %{}, via: %{}}, r, how)

  defp node(%{paths: paths, via: via}, r, how) do
    path = String.slice(r.path, 0, @path_chars)
    # Once "(other)" exists the 200 are taken and it is the 201st key.
    room = if Map.has_key?(paths, @other), do: @max_paths + 1, else: @max_paths
    key = if Map.has_key?(paths, path) or map_size(paths) < room, do: path, else: @other
    errors = if r.status in 500..599, do: 1, else: 0
    slot = duration_bucket(r.duration)

    paths =
      Map.update(paths, key, {1, errors, %{slot => 1}}, fn {n, e, hist} ->
        {n + 1, e + errors, bump(hist, slot)}
      end)

    via = if how == :via, do: bump(via, status_class(r.status)), else: via
    %{paths: paths, via: via}
  end

  defp bump(map, key, by \\ 1), do: Map.update(map, key, by, &(&1 + by))

  ## Percentiles

  @doc "The log-scale bucket of a duration in seconds (see the moduledoc)."
  def duration_bucket(seconds) do
    us = seconds * 1.0e6

    if us <= 1.0,
      do: 0,
      else: min(trunc(:math.log2(us) * @per_octave), @max_bucket)
  end

  @doc "The duration a bucket reports, in ms: its geometric midpoint."
  def bucket_ms(index), do: :math.pow(2, (index + 0.5) / @per_octave) / 1000

  @doc """
  Nearest-rank percentile (`p` in 0..1) of a histogram `%{bucket => count}`,
  in ms; nil when it is empty.
  """
  def percentile(hist, p) do
    total = hist |> Map.values() |> Enum.sum()

    if total == 0 do
      nil
    else
      rank = max(ceil(p * total), 1)

      hist
      |> Enum.sort()
      |> Enum.reduce_while(0, fn {index, n}, seen ->
        if seen + n >= rank, do: {:halt, bucket_ms(index)}, else: {:cont, seen + n}
      end)
    end
  end

  ## The window

  @doc """
  Adds one read (its lines and what `read/1` said about it) at `now_ms` and
  returns `{data, state}`: the collector's data over the last 300 s.

  `data` is `%{ready: true, window_s, rates, nodes, via, clients, stats}`:
  `nodes` maps a node id to `%{routes, latency}` for nodes with requests in
  the window; `rates` says whether this read's rates are known, and `via`
  then maps a node id to `%{rps, codes}` for nodes with path-route requests
  in this read; `stats` is `%{lines, bad_lines, skipped_bytes, rotations,
  unrouted}` over the window.
  """
  def step(state, lines, meta, now_ms) do
    bucket = lines |> bucket(state.router) |> Map.merge(meta)

    window =
      Enum.filter([{now_ms, bucket} | state.window], fn {at, _} -> at > now_ms - @window_ms end)

    dt_s = (now_ms - state.prev_at) / 1000
    rates = meta.rotations == 0 and meta.skipped_bytes == 0 and dt_s > 0
    buckets = Enum.map(window, &elem(&1, 1))

    data = %{
      ready: true,
      window_s: div(@window_ms, 1000),
      rates: rates,
      nodes: nodes(buckets),
      via: if(rates, do: via(bucket, dt_s), else: %{}),
      clients: clients(buckets),
      stats:
        Map.new([:lines, :bad_lines, :skipped_bytes, :rotations, :unrouted], fn key ->
          {key, buckets |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()}
        end)
    }

    {data, %{state | window: window, prev_at: now_ms}}
  end

  defp via(bucket, dt_s) do
    for {id, %{via: counts}} <- bucket.nodes, counts != %{}, into: %{} do
      codes = Map.new(@classes, &{&1, Map.get(counts, &1, 0) / dt_s})
      {id, %{rps: (counts |> Map.values() |> Enum.sum()) / dt_s, codes: codes}}
    end
  end

  defp nodes(buckets) do
    buckets
    |> Enum.flat_map(fn b -> Enum.map(b.nodes, fn {id, n} -> {id, n.paths} end) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, maps} -> {id, node_summary(maps)} end)
  end

  defp node_summary(maps) do
    paths = maps |> Enum.reduce(&Map.merge(&1, &2, fn _, a, b -> add(a, b) end)) |> fold()
    all = paths |> Map.values() |> Enum.reduce(&add/2)
    {total, _errors, hist} = all
    window_s = @window_ms / 1000

    routes =
      paths
      |> Enum.sort_by(fn {path, {n, _, _}} -> {-n, path} end)
      |> Enum.take(@top_routes)
      |> Enum.map(fn {path, {n, errors, hist}} ->
        %{
          path: path,
          count: n,
          rps: Float.round(n / window_s, 3),
          errors: errors,
          p95_ms: ms(percentile(hist, 0.95))
        }
      end)

    latency = %{
      p50_ms: ms(percentile(hist, 0.50)),
      p95_ms: ms(percentile(hist, 0.95)),
      p99_ms: ms(percentile(hist, 0.99)),
      count: total
    }

    %{routes: routes, latency: latency}
  end

  defp add({n1, e1, h1}, {n2, e2, h2}),
    do: {n1 + n2, e1 + e2, Map.merge(h1, h2, fn _, a, b -> a + b end)}

  # Keeps the 200 busiest paths of the window; the rest join "(other)".
  defp fold(paths) do
    {other, real} = Map.pop(paths, @other)

    {kept, rest} =
      real |> Enum.sort_by(fn {path, {n, _, _}} -> {-n, path} end) |> Enum.split(@max_paths)

    case Enum.map(rest, &elem(&1, 1)) ++ List.wrap(other) do
      [] -> Map.new(kept)
      folded -> kept |> Map.new() |> Map.put(@other, Enum.reduce(folded, &add/2))
    end
  end

  defp ms(value), do: Float.round(value, 2)

  defp clients(buckets) do
    sum = fn key ->
      Enum.reduce(buckets, %{}, &Map.merge(&2, Map.fetch!(&1, key), fn _, a, b -> a + b end))
    end

    classes = sum.(:clients)

    countries =
      sum.(:countries)
      |> Enum.sort_by(fn {code, n} -> {-n, code} end)
      |> Enum.take(@top_countries)
      |> Enum.map(fn {code, n} -> %{code: code, count: n} end)

    %{
      classes: Map.new(@client_classes, &{&1, Map.get(classes, &1, 0)}),
      countries: countries,
      window_s: div(@window_ms, 1000)
    }
  end
end
