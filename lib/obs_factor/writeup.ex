defmodule ObsFactor.Writeup do
  @moduledoc """
  A Markdown document about one slice of the tape, for people who are not
  on the floor: a postmortem, a weekly summary, a note for whoever owns an
  app. It is built from the same data the floor slices (`ObsFactor.Tape`,
  `ObsFactor.Insights`, the BEAM wire), so it says what the board said.

  A slice is a time range, and optionally:

    * `window` - a saved window's id: its range, title and note
    * `spec` - a wire filter (`ObsFactor.WireFilters` spec: apps, sevs,
      kinds, q), which narrows the timeline and the errors
    * `apps` - node ids: every section only about those buildings
    * `sections` - which of #{inspect(~w(summary incidents timeline hot beam errors db method))}
      (all by default)
    * `base_url` - where the floor is, for the replay links

  `build/1` returns `{:ok, %{title, markdown, from, to}}` or
  `{:error, reason}`. Writeups can be saved under an unguessable slug
  (`save/2`) and read without a login at `/w/<slug>.md`, until revoked
  (`delete/1`).
  """

  alias ObsFactor.{Insights, Tape, WireFilters}

  @sections ~w(summary incidents timeline hot beam errors db method)
  @error_kinds ~w(error warning failing crash handler)
  @max_rows 200

  def sections, do: @sections

  # ---- building ------------------------------------------------------------

  def build(opts) do
    db = Keyword.get(opts, :db, Tape.db())

    with {:ok, win} <- window(opts[:window], db),
         {:ok, from, to} <- range(win, opts),
         {:ok, spec} <- spec(opts[:spec]),
         {:ok, data} <- gather(from, to, db) do
      apps = opts[:apps] |> List.wrap() |> Enum.filter(&is_binary/1)
      sections = (opts[:sections] || @sections) |> Enum.filter(&(&1 in @sections))
      base = opts[:base_url] || "https://factory.bobbby.online"
      title = opts[:title] || (win && win.title) || "obs_factor: #{stamp(from)} – #{stamp(to)} UTC"

      ctx = %{from: from, to: to, win: win, spec: spec, apps: apps, base: base, data: data, labels: labels(data.frame)}
      body = Enum.map(sections, &section(&1, ctx)) |> Enum.reject(&(&1 in [nil, ""]))

      md = Enum.join([head(title, ctx) | body], "\n\n") <> "\n"
      {:ok, %{title: title, markdown: md, from: from, to: to}}
    end
  end

  defp window(nil, _), do: {:ok, nil}

  defp window(id, db) when is_integer(id) do
    with {:ok, list} <- Tape.windows(db) do
      case Enum.find(list, &(&1.id == id and is_nil(&1.pruned_at))) do
        nil -> {:error, "no saved window #{id}"}
        w -> {:ok, w}
      end
    end
  end

  defp window(other, _), do: {:error, "a window is an integer id, got #{inspect(other)}"}

  defp range(%{from: f, to: t}, _), do: {:ok, f, t}

  defp range(nil, opts) do
    case {opts[:from], opts[:to]} do
      {f, t} when is_integer(f) and is_integer(t) and t > f and t - f <= 31 * 86_400_000 -> {:ok, f, t}
      _ -> {:error, "a writeup needs a window id, or from and to (unix ms, from first, at most 31 days)"}
    end
  end

  defp spec(nil), do: {:ok, nil}
  defp spec(s), do: WireFilters.spec(s)

  defp gather(from, to, db) do
    with {:ok, insights} <- Insights.compute(from, to, db),
         {:ok, lanes} <- Tape.lanes(from, to, db),
         {:ok, wire} <- Tape.wire(from, to, 5000, db),
         {:ok, marks} <- Tape.marks(from, to, db),
         {:ok, beam} <- Tape.series(from, to, 240, db, "beam:"),
         {:ok, dbs} <- Tape.series(from, to, 240, db, "pg:"),
         {:ok, repos} <- Tape.series(from, to, 240, db, "repo:") do
      frame =
        case Tape.frame(to, db) do
          {:ok, _, json, _} -> Jason.decode!(json)
          _ -> %{"nodes" => []}
        end

      {:ok, %{insights: insights, lanes: lanes, wire: Enum.reverse(wire), wire_cut: length(wire) >= 5000, marks: marks, beam: beam, dbs: dbs, repos: repos, frame: frame}}
    end
  end

  defp labels(frame), do: Map.new(frame["nodes"] || [], &{&1["id"], &1["label"]})

  # ---- sections ------------------------------------------------------------

  defp head(title, ctx) do
    scope =
      [
        if(ctx.apps != [], do: "only #{Enum.map_join(ctx.apps, ", ", &label(ctx, &1))}"),
        if(ctx.spec, do: "wire filtered to #{describe(ctx.spec, ctx)}")
      ]
      |> Enum.reject(&is_nil/1)

    link = if ctx.win, do: "#{ctx.base}/?w=#{ctx.win.id}", else: "#{ctx.base}/?t=#{iso(ctx.from)}"

    """
    # #{title}

    **#{stamp(ctx.from)} – #{stamp(ctx.to)} UTC** (#{dur(ctx.to - ctx.from)})#{if scope != [], do: " · " <> Enum.join(scope, " · "), else: ""}

    #{if ctx.win && ctx.win.note, do: "> " <> String.replace(ctx.win.note, "\n", "\n> ") <> "\n\n", else: ""}Replay it on the floor: #{link}
    """
    |> String.trim_trailing()
  end

  defp section("summary", ctx) do
    s = ctx.data.insights.score
    c = ctx.data.insights.calm
    w = in_apps(ctx.data.wire, ctx)
    count = fn kinds -> Enum.count(w, &(&1.kind in kinds)) end
    beam_nodes = ctx.data.beam |> Enum.flat_map(fn [_, m] -> Map.keys(m) end) |> Enum.uniq() |> Enum.filter(&in_app?(ctx, beam_app(ctx, &1)))

    rows = [
      ["Fires started", s.started],
      ["Put out by someone", "#{s.put_out}#{if s.put_out_ms, do: " (median #{dur(s.put_out_ms)} to put out)", else: ""}"],
      ["Burned out with nobody coming", "#{s.burned_out}#{if s.unattended > 0, do: " (#{s.unattended} never looked at)", else: ""}"],
      ["Still burning at the end", s.burning],
      ["Median time to respond", if(s.respond_ms, do: dur(s.respond_ms), else: "nobody said they were looking")],
      ["Calm", if(c.share, do: "#{pct_calm(c.share)} of the tape had no alert", else: "no tape")],
      ["Longest burn", if(s.longest, do: "#{dur(s.longest.ms)}: #{label(ctx, s.longest.node)}, #{s.longest.title}", else: "none")],
      ["BEAM nodes on the tape", length(beam_nodes)],
      ["Deploys and restarts", count.(~w(deploy restart joined left))],
      ["Crashes", count.(~w(crash))],
      ["Leader moves", count.(~w(leader))],
      ["Errors and failing streams logged", count.(@error_kinds)]
    ]

    "## Summary\n\n" <> table(["Measure", "Value"], rows) <> "\n\n" <> note_if_scoped(ctx)
  end

  defp section("incidents", ctx) do
    alerts =
      ctx.data.lanes
      |> Enum.filter(fn [node, sev | _] -> sev == "alert" and in_app?(ctx, node) end)
      |> Enum.sort_by(fn [_, _, a | _] -> a end)

    if alerts == [] do
      "## Incidents\n\nNothing was on fire."
    else
      rows =
        for [node, _, a, b, frames, text] <- Enum.take(alerts, @max_rows) do
          [stamp(a), dur(b - a + Application.get_env(:obs_factor, :tick_ms, 5000)), label(ctx, node), text, frames, "[replay](#{ctx.base}/?t=#{iso(a - 5000)})"]
        end

      "## Incidents\n\nEach run of frames in which a building had an alert, a gap over 90 s ending one.\n\n" <>
        table(["Started", "Lasted", "Building", "Last said", "Frames", ""], rows) <> cut(alerts)
    end
  end

  defp section("timeline", ctx) do
    wire = ctx.data.wire |> in_apps(ctx) |> Enum.filter(&matches?(ctx.spec, &1))

    marks =
      for [at, kind, _id, node, _sev, title, by] <- ctx.data.marks, in_app?(ctx, node), ctx.spec == nil do
        %{at: at, who: label(ctx, node), what: "objective #{kind}", detail: "#{title}#{if by, do: " (by #{by})", else: ""}"}
      end

    events =
      (Enum.map(wire, &%{at: &1.at, who: &1.label || &1.app || "?", what: "#{&1.sev} · #{&1.kind}", detail: "#{&1.head}#{if &1.text, do: " — " <> &1.text, else: ""}"}) ++ marks)
      |> Enum.sort_by(& &1.at)

    if events == [] do
      "## Timeline\n\nNothing happened#{if ctx.spec, do: " that the filter lets through", else: ""}."
    else
      rows = for e <- Enum.take(events, @max_rows), do: [stamp(e.at), e.who, e.what, e.detail]
      "## Timeline\n\nThe BEAM wire and what people did about the objectives, oldest first.\n\n" <> table(["When", "Who", "What", ""], rows) <> cut(events) <>
        if(ctx.data.wire_cut, do: "\n\n_The wire held more than 5,000 items in this range: only the newest 5,000 were read._", else: "")
    end
  end

  defp section("hot", ctx) do
    hot = Enum.filter(ctx.data.insights.hot, &in_app?(ctx, &1.node))
    peaks = ctx.data.insights.peaks
    worst = ctx.data.insights.worst

    hot_md =
      if hot == [],
        do: "Nothing burned or smoked.",
        else: table(["Building", "On fire", "Smoking", "Objectives", "Last said"], for(h <- hot, do: [label(ctx, h.node), dur(h.alert_ms), dur(h.warn_ms), h.fires, h.text]))

    moments =
      [if(worst, do: "- **#{worst.alerts} alert#{if worst.alerts == 1, do: "", else: "s"}#{if worst.down > 0, do: ", #{worst.down} down", else: ""}** at #{stamp(worst.at)} UTC ([replay](#{ctx.base}/?t=#{iso(worst.at)}))")] ++
        for(p <- peaks, do: "- **5xx at #{p.err_rps}/s** at #{stamp(p.at)} UTC ([replay](#{ctx.base}/?t=#{iso(p.at - 5000)}))")

    "## Where it burned\n\n" <> hot_md <>
      if(Enum.reject(moments, &is_nil/1) != [], do: "\n\n### Worst moments\n\n" <> Enum.join(Enum.reject(moments, &is_nil/1), "\n"), else: "")
  end

  defp section("beam", ctx) do
    stats = series_stats(ctx.data.beam, ~w(procs mem bin reds rq sched mbox dist_out up))
    keys = stats |> Map.keys() |> Enum.filter(&in_app?(ctx, beam_app(ctx, &1))) |> Enum.sort()

    if keys == [] do
      "## The BEAM\n\nNo BEAM node on the tape in this range."
    else
      restarts = ctx.data.wire |> Enum.filter(&(&1.kind == "restart")) |> Enum.frequencies_by(& &1.member)

      rows =
        for k <- keys do
          s = stats[k]
          node = String.replace_prefix(k, "beam:", "")

          [node, range_cell(s["procs"], &num/1), range_cell(s["mem"], &bytes/1), "#{num(s["reds"][:mean])}/s (max #{num(s["reds"][:max])})",
           "#{num(s["rq"][:max])}/#{num(s["sched"][:last])}", num(s["mbox"][:max]), Map.get(restarts, node, 0)]
        end

      odd = ctx.data.wire |> in_apps(ctx) |> Enum.filter(&(&1.kind in ~w(outlier anomaly leader partition)))

      "## The BEAM\n\nPer node over the range: first → last (max). Reductions are a mean of the tape's samples.\n\n" <>
        table(["Node", "Processes", "Memory", "Reductions", "Run queue max / schedulers", "Biggest mailbox", "Restarts"], rows) <>
        if(odd == [], do: "", else: "\n\n### Out of the ordinary\n\n" <> Enum.map_join(odd, "\n", &"- #{stamp(&1.at)} · #{&1.label || &1.app}: #{&1.head}"))
    end
  end

  defp section("errors", ctx) do
    groups =
      ctx.data.wire
      |> in_apps(ctx)
      |> Enum.filter(&(&1.kind in @error_kinds and matches?(ctx.spec, &1)))
      |> Enum.group_by(&fingerprint/1)
      |> Enum.map(fn {_, items} -> {items, List.last(items)} end)
      |> Enum.sort_by(fn {items, last} -> {-length(items), -last.at} end)

    if groups == [] do
      "## Errors\n\nNo error, warning, failing stream or crash on the wire."
    else
      rows = for {items, last} <- groups, do: [length(items), last.label || last.app, last.kind, last.head, stamp(hd(items).at), stamp(last.at), last.text]

      "## Errors\n\nGrouped by app, kind and headline with numbers, pids and hex blanked.\n\n" <>
        table(["Count", "App", "Kind", "Headline", "First", "Last", "Latest detail"], rows)
    end
  end

  defp section("db", ctx) do
    pg = series_stats(ctx.data.dbs, ~w(conns commits))
    repo = series_stats(ctx.data.repos, ~w(rate ms err))
    app_of = fn series, k -> Enum.find_value(series, fn [_, m] -> m[k]["app"] end) end

    pg_rows =
      for {k, s} <- Enum.sort(pg), in_app?(ctx, app_of.(ctx.data.dbs, k)),
          do: [String.replace_prefix(k, "pg:", ""), label(ctx, app_of.(ctx.data.dbs, k)), range_cell(s["conns"], &num/1), "#{num(s["commits"][:mean])}/s (max #{num(s["commits"][:max])})"]

    repo_rows =
      for {k, s} <- Enum.sort(repo), in_app?(ctx, app_of.(ctx.data.repos, k)),
          do: [label(ctx, app_of.(ctx.data.repos, k)), "#{num(s["rate"][:mean])}/s (max #{num(s["rate"][:max])})", if(s["ms"][:mean], do: "#{num(s["ms"][:mean])} ms", else: "–"), if(s["err"][:max], do: "#{round(s["err"][:max] * 100)}%", else: "–")]

    tables =
      for n <- ctx.data.frame["nodes"] || [], in_app?(ctx, n["id"]), t = get_in(n, ["inside", "tables"]), is_list(t), t != [] do
        "### #{n["label"]}: busiest tables at the end of the range\n\n" <>
          table(["Table", "Repo", "Queries/s", "Average", "Total", "Errors"],
            for(r <- t, do: [r["table"] || "(no table: raw SQL, transactions)", r["repo"], fmt_rate(r["rate"]), fmt_ms(r["avg_ms"]), fmt_ms(r["total_ms"]), fmt_pct(r["err_rate"])]))
      end

    lvs =
      for n <- ctx.data.frame["nodes"] || [], in_app?(ctx, n["id"]), lv = get_in(n, ["inside", "liveviews"]), is_map(lv), is_integer(lv["total"]) do
        "- **#{n["label"]}**: #{lv["total"]} alive#{if lv["views"] != [], do: " (" <> Enum.map_join(Enum.take(lv["views"], 6), ", ", &"#{&1["view"]} #{&1["alive"]}") <> ")", else: ""}"
      end

    [
      "## Databases",
      if(pg_rows != [], do: "Each app's own Postgres database, first → last (max).\n\n" <> table(["Database", "App", "Connections", "Commits"], pg_rows)),
      if(repo_rows != [], do: "### Repo, as each app reports it\n\n" <> table(["App", "Queries", "Average", "Errors (max)"], repo_rows)),
      Enum.join(tables, "\n\n"),
      if(lvs != [], do: "### LiveViews alive at the end of the range\n\n" <> Enum.join(lvs, "\n"))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp section("method", ctx) do
    """
    ## How these numbers were made

    - From obs_factor's tape: one snapshot of the box every 5 s, kept for 6 h, then one a minute for 7 days; saved windows are kept whole. #{ctx.data.beam |> length()} samples of the BEAM series were read for this range.
    - An incident is a run of frames in which a building had an alert; a gap of more than 90 s ends it. "On fire" and "smoking" count each frame until the next, at most 2 minutes.
    - The BEAM wire compares each snapshot with the last: restarts, leaders moving, partitions, run queues past the schedulers, memory and atom jumps, mailboxes of 100 or more, logged errors, failing or surging Repo queries, nodes 10x the BEAM median or far from their own 30-minute normal.
    - Table times are Ecto's total_time (which includes waiting for a pool connection) as each app reports it; a join counts under its FROM table.
    - Generated #{stamp(System.system_time(:millisecond))} UTC by obs_factor.
    """
    |> String.trim_trailing()
  end

  @doc false
  def __pct__(share), do: pct_calm(share)

  # 15 s of fire in 2 h is not "100% calm": short of whole, it says so
  # floored on thousandths (0.998 * 100 is 99.79999...): never up to 100.0
  defp pct_calm(share) when share < 1 and share >= 0.995, do: "#{min(trunc(share * 1000 + 1.0e-9), 999) / 10}%"
  defp pct_calm(share) when share < 1 and share > 0.99, do: "#{Float.round(share * 100, 1)}%"
  defp pct_calm(share), do: "#{round(share * 100)}%"

  defp note_if_scoped(%{apps: []}), do: "_The fire counts are for the whole floor._"
  defp note_if_scoped(_), do: "_The fire counts are for the whole floor; the sections below are only about the buildings named above._"

  # ---- filtering ----------------------------------------------------------------

  defp in_app?(%{apps: []}, _), do: true
  defp in_app?(%{apps: apps}, node), do: node in apps

  defp in_apps(items, ctx), do: Enum.filter(items, &in_app?(ctx, &1.app))

  # a beam key's app: from the series, where each point carries it
  defp beam_app(ctx, key), do: Enum.find_value(ctx.data.beam, fn [_, m] -> m[key]["app"] end)

  @doc "Does a wire item pass a filter spec (as board.js's `matches`)? A nil spec passes everything."
  def matches?(nil, _), do: true

  def matches?(spec, w) do
    (spec["apps"] in [nil, []] or w.app in spec["apps"]) and
      (spec["sevs"] in [nil, []] or w.sev in spec["sevs"]) and
      (spec["kinds"] in [nil, []] or w.kind in spec["kinds"]) and
      text_match?(spec["q"], w)
  end

  defp text_match?(q, _) when q in [nil, ""], do: true

  defp text_match?(q, w) do
    hay = String.downcase("#{w.head} #{w.text} #{w.member} #{w.label}")
    String.contains?(hay, String.downcase(String.trim(q)))
  end

  defp describe(spec, ctx) do
    [
      if(spec["apps"] != [], do: Enum.map_join(spec["apps"], ", ", &label(ctx, &1))),
      if(spec["sevs"] != [], do: Enum.join(spec["sevs"], "/")),
      if(spec["kinds"] != [], do: Enum.join(spec["kinds"], ", ")),
      if(spec["q"] != "", do: "“#{spec["q"]}”")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "everything"
      d -> d
    end
  end

  defp fingerprint(w),
    do: {w.app, w.kind, Regex.replace(~r/#PID<[^>]+>|<\d+\.\d+\.\d+>|\b0x[0-9a-f]+\b|\d+(\.\d+)*/i, w.head || "", "#")}

  # ---- series -------------------------------------------------------------------

  # key => field => %{first, last, min, max, mean}, over every point that has it
  defp series_stats(series, fields) do
    series
    |> Enum.flat_map(fn [_, m] -> Enum.map(m, fn {k, v} -> {k, v} end) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {k, points} ->
      {k,
       Map.new(fields, fn f ->
         vals = for p <- points, v = p[f], is_number(v), do: v
         {f, if(vals == [], do: %{}, else: %{first: hd(vals), last: List.last(vals), min: Enum.min(vals), max: Enum.max(vals), mean: Enum.sum(vals) / length(vals)})}
       end)}
    end)
  end

  defp range_cell(%{first: a, last: b, max: m}, f), do: "#{f.(a)} → #{f.(b)} (#{f.(m)})"
  defp range_cell(_, _), do: "–"

  # ---- markdown -----------------------------------------------------------------

  @doc false
  def table(headers, rows) do
    line = fn cells -> "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |" end
    Enum.join([line.(headers), "|" <> String.duplicate(" --- |", length(headers)) | Enum.map(rows, line)], "\n")
  end

  # a table cell: no pipes or newlines to break the row, nothing that looks
  # like HTML to a renderer that allows it
  defp cell(nil), do: "–"
  defp cell(v) when is_number(v), do: num(v)

  defp cell(v) do
    v
    |> to_string()
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.replace("|", "\\|")
    |> String.replace("<", "&lt;")
    |> String.slice(0, 300)
  end

  defp cut(items) when length(items) > @max_rows, do: "\n\n_#{length(items) - @max_rows} more not shown._"
  defp cut(_), do: ""

  defp label(_ctx, nil), do: "the observer"
  defp label(ctx, id), do: Map.get(ctx.labels, id) || id

  defp stamp(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp dur(nil), do: "–"
  defp dur(ms) when ms < 60_000, do: "#{round(ms / 1000)}s"
  defp dur(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
  defp dur(ms) when ms < 172_800_000, do: "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"
  defp dur(ms), do: "#{div(ms, 86_400_000)}d #{rem(div(ms, 3_600_000), 24)}h"

  defp num(nil), do: "–"
  defp num(n) when is_integer(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp num(n) when is_float(n) and abs(n) >= 1000, do: num(round(n))
  defp num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2) |> String.replace(~r/\.?0+$/, "")

  defp bytes(nil), do: "–"
  defp bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  defp bytes(b) when b >= 1_048_576, do: "#{round(b / 1_048_576)} MB"
  defp bytes(b), do: "#{round(b / 1024)} KB"

  defp fmt_rate(nil), do: "–"
  defp fmt_rate(r), do: "#{num(r)}/s"
  defp fmt_ms(nil), do: "–"
  defp fmt_ms(m), do: "#{num(m)} ms"
  defp fmt_pct(nil), do: "–"
  defp fmt_pct(p), do: "#{round(p * 100)}%"

  # ---- saved, shareable ------------------------------------------------------------

  @ddl """
  CREATE TABLE IF NOT EXISTS writeups (
    slug text PRIMARY KEY,
    title text NOT NULL,
    from_at timestamptz NOT NULL,
    to_at timestamptz NOT NULL,
    options jsonb NOT NULL,
    markdown text NOT NULL,
    by text,
    created_at timestamptz NOT NULL DEFAULT now()
  )
  """

  @doc """
  Keep a built writeup under a new unguessable slug (24 random bytes,
  url-safe): `{:ok, %{slug, title, ...}}`. Anyone with `/w/<slug>.md` can
  read it, without logging in, until it is deleted.
  """
  def save(%{title: title, markdown: md, from: f, to: t}, options, by, db \\ Tape.db()) do
    slug = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    with :ok <- ensure(db),
         {:ok, _} <- q(db, "INSERT INTO writeups (slug, title, from_at, to_at, options, markdown, by) VALUES ($1, $2, $3, $4, $5, $6, $7)",
           [slug, title, dt(f), dt(t), options, md, by]) do
      {:ok, %{slug: slug, title: title, from: f, to: t, by: by}}
    end
  end

  @doc "Every saved writeup, newest first, without its text."
  def list(db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT slug, title, from_at, to_at, by, created_at FROM writeups ORDER BY created_at DESC LIMIT 200", []) do
      {:ok, for([s, t, f, to, by, c] <- rows, do: %{slug: s, title: t, from: ms(f), to: ms(to), by: by, created_at: ms(c)})}
    end
  end

  @doc "A saved writeup's Markdown by slug: `{:ok, title, markdown}` or `:none`."
  def fetch(slug, db \\ Tape.db()) when is_binary(slug) do
    with true <- Regex.match?(~r/\A[A-Za-z0-9_-]{32}\z/, slug),
         :ok <- ensure(db),
         {:ok, %{rows: [[title, md]]}} <- q(db, "SELECT title, markdown FROM writeups WHERE slug = $1", [slug]) do
      {:ok, title, md}
    else
      _ -> :none
    end
  end

  @doc "Revoke a shared writeup: its link stops working. `{:ok, slug}` or `{:error, reason}`."
  def delete(slug, db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, %{num_rows: 1}} <- q(db, "DELETE FROM writeups WHERE slug = $1", [slug]) do
      {:ok, slug}
    else
      {:ok, %{num_rows: 0}} -> {:error, "no writeup #{slug}"}
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  defp ensure(db) do
    case q(db, @ddl, []) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)
end
