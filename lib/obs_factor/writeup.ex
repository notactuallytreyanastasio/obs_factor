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
    * `compare` - `"week"` or `"month"`: a small extra section comparing
      the range with the same period a week (7 days) or a calendar month
      earlier, both from `ObsFactor.Rollups.summarize/3`

  A range may be up to 92 days. The tape keeps 7; where a range starts an
  hour or more before the tape's first frame, the summary, BEAM and
  database sections add (or, with nothing on the tape, are) the hourly
  rollups (`ObsFactor.Rollups`) of that part, and say so. Incidents, the
  timeline, where it burned and errors need the frames and the wire, so
  they only cover the tape's part.

  `build/1` returns `{:ok, %{title, markdown, from, to}}` or
  `{:error, reason}`. Writeups can be saved under an unguessable slug
  (`save/2`) and read without a login at `/w/<slug>.md`, until revoked
  (`delete/1`).
  """

  alias ObsFactor.{Insights, Rollups, Tape, WireFilters}

  @sections ~w(summary incidents timeline hot beam errors db method)
  @error_kinds ~w(error warning failing crash handler)
  @max_rows 200
  @max_range_ms 92 * 86_400_000
  @hour 3_600_000

  def sections, do: @sections

  # ---- building ------------------------------------------------------------

  def build(opts) do
    db = Keyword.get(opts, :db, Tape.db())

    with {:ok, win} <- window(opts[:window], db),
         {:ok, from, to} <- range(win, opts),
         {:ok, spec} <- spec(opts[:spec]),
         {:ok, split} <- split(from, to, db),
         {:ok, old} <- old_part(split, db),
         {:ok, cmp} <- compare(opts[:compare], from, to, db),
         {:ok, data} <- gather(from, to, db) do
      apps = opts[:apps] |> List.wrap() |> Enum.filter(&is_binary/1)
      sections = (opts[:sections] || @sections) |> Enum.filter(&(&1 in @sections))
      base = opts[:base_url] || "https://factory.bobbby.online"
      title = opts[:title] || (win && win.title) || "obs_factor: #{stamp(from)} – #{stamp(to)} UTC"

      ctx = %{from: from, to: to, win: win, spec: spec, apps: apps, base: base, data: data, labels: labels(data.frame),
              split: split, old: old, cmp: cmp}
      # the comparison goes after the summary, or first when there is none
      sections = if cmp, do: List.insert_at(sections, if("summary" in sections, do: Enum.find_index(sections, &(&1 == "summary")) + 1, else: 0), "compare"), else: sections
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
      {f, t} when is_integer(f) and is_integer(t) and t > f and t - f <= @max_range_ms -> {:ok, f, t}
      _ -> {:error, "a writeup needs a window id, or from and to (unix ms, from first, at most 92 days)"}
    end
  end

  # Which part of [from, to) is on the tape and which only in the hourly
  # rollups. `tape`: where the tape's part starts (nil: nothing of the range
  # is on the tape); `old`: {from, to} for the rollups (nil: none). The old
  # part ends at the hour the tape starts in: a range that starts a few
  # minutes before the tape (a weekly writeup, as the tape thins) has none.
  defp split(from, to, db) do
    with {:ok, start} <- Rollups.tape_start(db) do
      cond do
        start == nil or to <= start -> {:ok, %{tape: nil, old: {from, to}, start: start}}
        from < div(start, @hour) * @hour -> {:ok, %{tape: start, old: {from, div(start, @hour) * @hour}, start: start}}
        true -> {:ok, %{tape: from, old: nil, start: start}}
      end
    end
  end

  defp old_part(%{old: nil}, _db), do: {:ok, nil}
  defp old_part(%{old: {f, t}}, db), do: Rollups.summarize(f, t, db)

  defp compare(nil, _, _, _), do: {:ok, nil}

  defp compare(by, from, to, db) when by in ["week", "month"] do
    {pf, pt} = earlier(by, from, to)

    with {:ok, now} <- Rollups.summarize(from, to, db),
         {:ok, then} <- Rollups.summarize(pf, pt, db) do
      {:ok, %{by: by, now: now, then: then, from: pf, to: pt}}
    end
  end

  defp compare(other, _, _, _), do: {:error, "compare is week or month, got #{inspect(other)}"}

  @doc "The same period a week (7 days) or a calendar month earlier: `{from, to}`."
  def earlier("week", from, to), do: {from - 7 * 86_400_000, to - 7 * 86_400_000}

  def earlier("month", from, to) do
    back = fn ms -> ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift(month: -1) |> DateTime.to_unix(:millisecond) end
    {back.(from), back.(to)}
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

    sources =
      case ctx.split do
        %{old: nil} -> ""
        %{tape: nil} -> "_All of it from hourly rollups: the tape keeps 7 days#{if ctx.split.start, do: " and starts at #{stamp(ctx.split.start)}", else: " and is empty"}._\n\n"
        %{old: {f, t}} -> "_#{stamp(f)} – #{stamp(t)} from hourly rollups (summary, BEAM, databases only); from #{stamp(ctx.split.start)}, the tape._\n\n"
      end

    """
    # #{title}

    **#{stamp(ctx.from)} – #{stamp(ctx.to)} UTC** (#{dur(ctx.to - ctx.from)})#{if scope != [], do: " · " <> Enum.join(scope, " · "), else: ""}

    #{if ctx.win && ctx.win.note, do: "> " <> String.replace(ctx.win.note, "\n", "\n> ") <> "\n\n", else: ""}#{sources}Replay it on the floor: #{link}
    """
    |> String.trim_trailing()
  end

  defp section("summary", %{split: %{tape: nil}} = ctx), do: "## Summary\n\n" <> old_summary(ctx)

  defp section("summary", ctx),
    do: tape_summary(ctx) <> if(ctx.old, do: "\n\n### Before the tape, from hourly rollups\n\n" <> old_summary(ctx), else: "")

  defp section("beam", %{split: %{tape: nil}} = ctx), do: "## The BEAM\n\n" <> old_beam(ctx)

  defp section("beam", ctx),
    do: tape_beam(ctx) <> if(ctx.old, do: "\n\n### Before the tape, from hourly rollups\n\n" <> old_beam(ctx), else: "")

  defp section("db", %{split: %{tape: nil}} = ctx), do: "## Databases\n\n" <> old_db(ctx)

  defp section("db", ctx),
    do: tape_db(ctx) <> if(ctx.old, do: "\n\n### Before the tape, from hourly rollups\n\n" <> old_db(ctx), else: "")

  defp section("compare", ctx), do: compare_section(ctx)

  # frames and the wire are gone: say so rather than "nothing happened"
  defp section(s, %{split: %{tape: nil}}) when s in ~w(incidents timeline hot errors) do
    title = %{"incidents" => "Incidents", "timeline" => "Timeline", "hot" => "Where it burned", "errors" => "Errors"}[s]
    "## #{title}\n\n_Not on the tape any more: it keeps 7 days, and this section needs its frames and wire. The summary has what the hourly rollups kept._"
  end

  defp section("method", ctx) do
    method(ctx) <>
      if(ctx.old || ctx.cmp,
        do: "\n- Hourly rollups (`tape_rollups`, kept 13 months) are made from the tape before it is thinned: per UTC hour, maxima, time-weighted means, seconds with an alert per building, wire items by kind. Ranges in rollups are whole hours#{if (ctx.old && ctx.old.widened) || (ctx.cmp && (ctx.cmp.now.widened || ctx.cmp.then.widened)), do: " (an edge hour off the tape counts whole here)", else: ""}.",
        else: "")
  end

  defp section("errors", ctx), do: tape_errors(ctx)
  defp section(name, ctx), do: tape_section(name, ctx)

  defp tape_summary(ctx) do
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

  defp tape_section("incidents", ctx) do
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

  defp tape_section("timeline", ctx) do
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

  defp tape_section("hot", ctx) do
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

  defp tape_beam(ctx) do
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

  defp tape_errors(ctx) do
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

  defp tape_db(ctx) do
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

  defp method(ctx) do
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

  # ---- from hourly rollups ------------------------------------------------------

  defp old_summary(%{old: %{hours: 0}, split: %{old: {f, t}}}),
    do: "No hourly rollups for #{stamp(f)} – #{stamp(t)} UTC: they start with the tape obs_factor had when it began keeping them."

  defp old_summary(%{old: o, split: %{old: {f, t}}} = ctx) do
    lanes = for {node, l} <- o.lanes, in_app?(ctx, node), l["alert_s"] > 0, do: {node, l["alert_s"]}
    longest = lanes |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(3)
    count = fn kinds -> wire_count(o, ctx, kinds) end

    rows = [
      ["Hours on record", "#{o.hours} of #{div(t - f + @hour - 1, @hour)}"],
      ["Calm", if(o.tape_s > 0, do: "#{pct_calm(1 - o.alert_s / o.tape_s)} of the recorded time had no alert", else: "no tape")],
      ["Time with an alert", dur(round(o.alert_s * 1000))],
      ["Time with a warning", dur(round(o.warn_s * 1000))],
      ["Most alerts at once", o.alerts_max],
      ["Most buildings down at once", o.down_max],
      ["Requests through the proxies", rate(o.rps_mean, o.rps_max)],
      ["5xx through the proxies", rate(o.err_rps_mean, o.err_rps_max)],
      ["Longest burning", if(longest == [], do: "none", else: Enum.map_join(longest, ", ", fn {n, s} -> "#{label(ctx, n)} #{dur(round(s * 1000))}" end))],
      ["Deploys and restarts", count.(~w(deploy restart joined left))],
      ["Crashes", count.(~w(crash))],
      ["Leader moves", count.(~w(leader))],
      ["Errors and failing streams logged", count.(@error_kinds)]
    ]

    nodes = for {n, m} <- Enum.sort(o.nodes), in_app?(ctx, n), m["rps"], do: [label(ctx, n), rate(m["rps"]["mean"], m["rps"]["max"]), rate(m["err_rps"]["mean"], m["err_rps"]["max"])]

    "_#{stamp(f)} – #{stamp(t)} UTC, from hourly rollups._\n\n" <> table(["Measure", "Value"], rows) <>
      if(nodes == [], do: "", else: "\n\nPer building, mean (max):\n\n" <> table(["Building", "Requests", "5xx"], nodes))
  end

  defp wire_count(o, %{apps: []}, kinds), do: Enum.sum(for {k, n} <- o.wire, k in kinds, do: n)
  defp wire_count(o, %{apps: apps}, kinds), do: Enum.sum(for a <- apps, {k, n} <- o.wire_apps[a] || %{}, k in kinds, do: n)

  defp old_beam(%{old: %{hours: 0}}), do: "No hourly rollups for this part."

  defp old_beam(ctx) do
    rows =
      for {k, m} <- Enum.sort(ctx.old.beam), in_app?(ctx, m["app"]) do
        [String.replace_prefix(k, "beam:", ""), mean_max(m["procs"], &num/1), mean_max(m["mem"], &bytes/1), mean_max(m["reds"], &"#{num(&1)}/s"),
         mean_max(m["rq"], &num/1), num(m["mbox"]["max"])]
      end

    if rows == [],
      do: "No BEAM node in the hourly rollups of this part.",
      else: "Per node, mean (max) over the hours.\n\n" <> table(["Node", "Processes", "Memory", "Reductions", "Run queue", "Biggest mailbox"], rows)
  end

  defp old_db(%{old: %{hours: 0}}), do: "No hourly rollups for this part."

  defp old_db(ctx) do
    rows =
      for {k, m} <- Enum.sort(ctx.old.dbs), in_app?(ctx, m["app"]),
          do: [String.replace_prefix(k, "pg:", ""), label(ctx, m["app"]), mean_max(m["conns"], &num/1), mean_max(m["commits"], &"#{num(&1)}/s")]

    if rows == [],
      do: "No app database in the hourly rollups of this part.",
      else: "Each app's own Postgres database, mean (max) over the hours.\n\n" <> table(["Database", "App", "Connections", "Commits"], rows)
  end

  defp compare_section(%{cmp: c} = ctx) do
    {a, b} = {c.now, c.then}
    calm = fn r -> if r.tape_s > 0, do: 1 - r.alert_s / r.tape_s end
    count = fn r, kinds -> wire_count(r, ctx, kinds) end
    what = if c.by == "week", do: "last week", else: "last month"

    rows =
      for {name, x, y, fmt} <- [
            {"Hours on record", a.hours, b.hours, &num/1},
            {"Calm", calm.(a), calm.(b), &pct_calm/1},
            {"Time with an alert", round(a.alert_s * 1000), round(b.alert_s * 1000), &dur/1},
            {"Most alerts at once", a.alerts_max, b.alerts_max, &num/1},
            {"Requests through the proxies, mean", a.rps_mean, b.rps_mean, &"#{num(&1)}/s"},
            {"5xx through the proxies, mean", a.err_rps_mean, b.err_rps_mean, &"#{num(&1)}/s"},
            {"5xx, worst hour's max", a.err_rps_max, b.err_rps_max, &"#{num(&1)}/s"},
            {"Deploys and restarts", count.(a, ~w(deploy restart joined left)), count.(b, ~w(deploy restart joined left)), &num/1},
            {"Crashes", count.(a, ~w(crash)), count.(b, ~w(crash)), &num/1},
            {"Errors and failing streams logged", count.(a, @error_kinds), count.(b, @error_kinds), &num/1}
          ] do
        [name, if(x == nil, do: "–", else: fmt.(x)), if(y == nil, do: "–", else: fmt.(y)), change(x, y)]
      end

    "## Compared with #{what}\n\n_#{stamp(c.from)} – #{stamp(c.to)} UTC, both periods from hourly rollups (the edges and the hour in progress from the tape)._\n\n" <>
      table(["Measure", "This period", String.capitalize(what), "Change"], rows) <>
      if(b.hours == 0, do: "\n\n_Nothing was recorded #{what}: no rollups go back that far._", else: "")
  end

  defp change(x, y) when is_number(x) and is_number(y) do
    cond do
      x == y -> "same"
      y == 0 -> "+#{num(x)}"
      round((x - y) / abs(y) * 100) == 0 -> "same"
      true -> "#{if x > y, do: "+", else: ""}#{round((x - y) / abs(y) * 100)}%"
    end
  end

  defp change(_, _), do: "–"

  defp rate(nil, _), do: "–"
  defp rate(mean, max), do: "#{num(mean)}/s (max #{num(max)})"

  defp mean_max(%{"mean" => m, "max" => x}, f) when is_number(m), do: "#{f.(m)} (#{f.(x)})"
  defp mean_max(_, _), do: "–"

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
