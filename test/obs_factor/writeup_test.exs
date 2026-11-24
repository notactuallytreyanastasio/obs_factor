defmodule ObsFactor.WriteupTest do
  @moduledoc """
  Writeups against a real Postgres, as ObsFactor.TapeTest: a tape is
  recorded (frames with BEAM and database numbers, wire items, an
  objective), then written up whole, by app, through a filter, saved,
  shared over HTTP and revoked.
  """
  use ObsFactorWeb.ConnCase, async: false

  alias ObsFactor.{Objectives, Tape, Writeup}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({Objectives, db: db})
    topic = "writeup_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, topic)
    start_supervised!({Tape, db: db, topic: topic, thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)
    t0 = System.system_time(:millisecond) - 600_000

    snap = fn alerts ->
      %{
        at: "x",
        attention: alerts,
        nodes: [
          %{id: "caddy", label: "Caddy", kind: "proxy", status: "working", hosts: [%{rps: 2.0, err_rps: 0.0}]},
          %{id: "marginalia", label: "Marginalia", kind: "app", status: "working", hosts: [],
            inside: %{ok: true, runtime: %{kind: "beam"}, tables: [%{repo: "Marginalia.Repo", table: "links", rate: 1.5, avg_ms: 2.0, total_ms: 30.0, err_rate: 0.0}],
                      liveviews: %{total: 3, views: [%{view: "MarginaliaWeb.ReadLive", alive: 3}]}}},
          %{id: "blog", label: "Blog", kind: "app", status: "working", hosts: []}
        ]
      }
    end

    beam = fn procs -> %{"beam:marginalia@10" => %{app: "marginalia", procs: procs, mem: 150_000_000, reds: 6000.0, rq: 0, sched: 4, mbox: 0},
                         "beam:blog@1" => %{app: "blog", procs: 800, mem: 160_000_000, reds: 1_000_000.0, rq: 1, sched: 4},
                         "pg:marginalia_prod" => %{app: "marginalia", conns: 12, commits: 0.4}} end
    wire = fn at, app, kind, sev, head -> %{at: at, app: app, label: String.capitalize(app), member: nil, kind: kind, sev: sev, head: head, text: "detail of #{head}"} end

    record = fn at, s, b, w ->
      Tape.record(at, Jason.encode!(s), Tape.summary(s, %{}, b, w))
      assert_receive {:tape_frame, %{at: ^at}}, 2_000
    end

    record.(t0, snap.([]), beam.(500), [])
    record.(t0 + 5_000, snap.([%{node: "marginalia", severity: "alert", text: "Marginalia: 5xx at 2/s"}]), beam.(520), [wire.(t0 + 5_000, "marginalia", "error", "alert", "error in Runs at 0.123.0")])
    record.(t0 + 10_000, snap.([%{node: "marginalia", severity: "alert", text: "Marginalia: 5xx at 3/s"}]), beam.(540), [wire.(t0 + 10_000, "marginalia", "error", "alert", "error in Runs at 0.456.0")])
    record.(t0 + 15_000, snap.([]), beam.(530), [wire.(t0 + 15_000, "blog", "outlier", "warn", "reductions 1,000,000/s: 40x the BEAM median")])
    %{t0: t0, to: t0 + 20_000}
  end

  test "a whole-floor writeup has every section, built from the tape", %{t0: t0, to: to} do
    {:ok, w} = Writeup.build(from: t0, to: to, base_url: "https://factory.test")
    md = w.markdown
    assert md =~ ~r/^# obs_factor: \d{4}-\d\d-\d\d \d\d:\d\d:\d\d – .* UTC$/m
    for h <- ["## Summary", "## Incidents", "## Timeline", "## Where it burned", "## The BEAM", "## Errors", "## Databases", "## How these numbers were made"], do: assert(md =~ h)
    # one incident: the two alert frames on Marginalia, with a replay link
    assert md =~ ~r/\| [^|]+ \| 10s \| Marginalia \| Marginalia: 5xx at 3\/s \| 2 \| \[replay\]\(https:\/\/factory\.test\/\?t=/
    # the two errors differ only by pid: one group of 2
    assert md =~ ~r/\| 2 \| Marginalia \| error \| error in Runs at 0\.456\.0 \|/
    # the BEAM table: first → last (max)
    assert md =~ "| marginalia@10 | 500 → 530 (540) |"
    assert md =~ "| marginalia_prod | Marginalia | 12 → 12 (12) |"
    assert md =~ "| links | Marginalia.Repo | 1.5/s | 2 ms | 30 ms | 0% |"
    assert md =~ "**Marginalia**: 3 alive (MarginaliaWeb.ReadLive 3)"
  end

  test "by app: the other buildings are left out of every section", %{t0: t0, to: to} do
    {:ok, w} = Writeup.build(from: t0, to: to, apps: ["blog"])
    refute w.markdown =~ "marginalia@10"
    refute w.markdown =~ "error in Runs"
    assert w.markdown =~ "blog@1"
    assert w.markdown =~ "only Blog"
  end

  test "through a wire filter, and only the sections asked for", %{t0: t0, to: to} do
    {:ok, w} = Writeup.build(from: t0, to: to, spec: %{"kinds" => ["outlier"]}, sections: ["timeline"])
    assert w.markdown =~ "reductions 1,000,000/s"
    refute w.markdown =~ "error in Runs"
    refute w.markdown =~ "## Summary"
    assert w.markdown =~ "wire filtered to outlier"
  end

  test "a saved window gives the range, the title and the note" do
    {:ok, win} = Tape.save_window(%{"from" => System.system_time(:millisecond) - 600_000, "to" => System.system_time(:millisecond) - 580_000, "title" => "the 5xx", "note" => "restarted Runs by hand"})
    {:ok, w} = Writeup.build(window: win.id, sections: ["summary"], base_url: "https://f.test")
    assert w.title == "the 5xx"
    assert w.markdown =~ "# the 5xx"
    assert w.markdown =~ "> restarted Runs by hand"
    assert w.markdown =~ "https://f.test/?w=#{win.id}"
  end

  test "bad slices are refused, saying why" do
    assert {:error, "a writeup needs a window id" <> _} = Writeup.build([])
    assert {:error, "no saved window 999999"} = Writeup.build(window: 999_999)
  end

  test "saved, read by its link without a login, revoked", %{conn: conn, t0: t0, to: to} do
    {:ok, w} = Writeup.build(from: t0, to: to, sections: ["summary"])
    {:ok, saved} = Writeup.save(w, %{from: t0, to: to}, "bg")
    assert String.length(saved.slug) == 32
    assert {:ok, [%{slug: s, by: "bg"}]} = Writeup.list()
    assert s == saved.slug

    resp = get(conn, "/w/#{saved.slug}.md")
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> hd() =~ "text/markdown"
    assert resp.resp_body == w.markdown

    assert get(build_conn(), "/w/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.md").status == 404
    assert get(build_conn(), "/w/../../etc/passwd").status == 404
    {:ok, _} = Writeup.delete(saved.slug)
    assert get(build_conn(), "/w/#{saved.slug}.md").status == 404
  end

  test "the download is behind the login", %{conn: conn, t0: t0, to: to} do
    assert get(conn, "/api/writeup.md?from=#{t0}&to=#{to}").status == 401
    authed = build_conn() |> post("/login", %{"password" => Application.fetch_env!(:obs_factor, :password)}) |> recycle()
    resp = get(authed, "/api/writeup.md?from=#{t0}&to=#{to}&sections=summary,beam&apps=marginalia")
    assert resp.status == 200
    assert get_resp_header(resp, "content-disposition") |> hd() =~ ~r/attachment; filename=".+\.md"/
    assert resp.resp_body =~ "## The BEAM"
    refute resp.resp_body =~ "## Incidents"
    assert build_conn() |> post("/login", %{"password" => Application.fetch_env!(:obs_factor, :password)}) |> recycle() |> get("/api/writeup.md?from=1&to=0") |> json_response(400)
  end
end
