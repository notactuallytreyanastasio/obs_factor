defmodule ObsFactor.TokensSchedulesTest do
  @moduledoc """
  Script tokens and scheduled writeups, against a real Postgres (as
  ObsFactor.WriteupTest).
  """
  use ObsFactorWeb.ConnCase, async: false

  alias ObsFactor.{ApiTokens, Tape, Writeup}
  alias ObsFactor.Writeup.Schedules

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")
  @day 86_400_000

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS api_tokens, writeup_schedules, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({ObsFactor.Objectives, db: db})
    start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)
    %{db: db}
  end

  describe "tokens" do
    test "made once, kept only as a hash, good for its scope, revoked", %{db: db} do
      {:ok, t} = ApiTokens.create("nightly cron", ["writeups:read"], "bg")
      assert "obsf_" <> rest = t.token
      assert byte_size(rest) == 43
      # the token itself is nowhere in the table
      dump = Postgrex.query!(db, "SELECT * FROM api_tokens", []).rows |> inspect()
      refute dump =~ rest
      assert {:ok, [%{name: "nightly cron", hint: "obsf_" <> _, last_used_at: nil}]} = ApiTokens.list()

      assert {:ok, %{name: "nightly cron"}} = ApiTokens.verify(t.token, "writeups:read")
      assert {:ok, [%{last_used_at: used}]} = ApiTokens.list()
      assert is_integer(used)
      assert {:error, "this token may not" <> _} = ApiTokens.verify(t.token, "everything:write")
      assert {:error, "unknown or revoked token"} = ApiTokens.verify("obsf_nope", "writeups:read")
      assert {:error, "not an obs_factor token"} = ApiTokens.verify("hunter2", "writeups:read")
      assert {:ok, _} = ApiTokens.revoke(t.id)
      assert {:error, "unknown or revoked token"} = ApiTokens.verify(t.token, "writeups:read")
      assert {:error, "a token needs a name" <> _} = ApiTokens.create(" ")
    end

    test "a bearer token reads /api/writeup.md without a session; a bad one is refused, not sent to the session", %{conn: conn} do
      {:ok, t} = ApiTokens.create("curl")
      to = System.system_time(:millisecond)
      path = "/api/writeup.md?from=#{to - 60_000}&to=#{to}&sections=summary"

      resp = conn |> put_req_header("authorization", "Bearer #{t.token}") |> get(path)
      assert resp.status == 200
      assert resp.resp_body =~ "## Summary"

      assert build_conn() |> put_req_header("authorization", "Bearer obsf_wrong") |> get(path) |> json_response(401) == %{"error" => "unknown or revoked token"}
      assert build_conn() |> get(path) |> json_response(401) |> Map.get("error") =~ "Bearer"

      # a logged-in browser with a bad bearer is refused too: the bearer wins
      authed = build_conn() |> post("/login", %{"password" => Application.fetch_env!(:obs_factor, :password)}) |> recycle()
      assert authed |> put_req_header("authorization", "Bearer obsf_wrong") |> get(path) |> json_response(401)
      # the rest of the API is still session-only
      assert build_conn() |> put_req_header("authorization", "Bearer #{t.token}") |> get("/api/objectives") |> json_response(401)
    end
  end

  describe "schedules" do
    # 2026-11-23 is a Monday
    @mon_10 DateTime.to_unix(~U[2026-11-23 10:00:00Z], :millisecond)

    test "the last instant, daily and weekly" do
      assert Schedules.last_instant(%{every: "daily", hour: 9}, @mon_10) == @mon_10 - 3_600_000
      assert Schedules.last_instant(%{every: "daily", hour: 11}, @mon_10) == @mon_10 + 3_600_000 - @day
      # weekly, Monday 09:00: today; Sunday 09:00: yesterday; Monday 11:00: a week ago
      assert Schedules.last_instant(%{every: "weekly", hour: 9, weekday: 1}, @mon_10) == @mon_10 - 3_600_000
      assert Schedules.last_instant(%{every: "weekly", hour: 9, weekday: 7}, @mon_10) == @mon_10 - 3_600_000 - @day
      assert Schedules.last_instant(%{every: "weekly", hour: 11, weekday: 1}, @mon_10) == @mon_10 + 3_600_000 - 7 * @day
      assert Schedules.next_instant(%{every: "daily", hour: 9}, @mon_10) == @mon_10 - 3_600_000 + @day
    end

    test "due after the instant, not before the schedule existed, once" do
      s = %{every: "daily", hour: 9, created_at: @mon_10 - 2 * @day, last_run_at: nil}
      assert {:due, i} = Schedules.due(s, @mon_10)
      assert i == @mon_10 - 3_600_000
      assert :no = Schedules.due(%{s | last_run_at: i}, @mon_10)
      # made at 10:00 for 09:00: tomorrow, not now
      assert :no = Schedules.due(%{s | created_at: @mon_10}, @mon_10)
    end

    test "saved checked; a run writes up the period, saves it, posts the webhook, records it" do
      assert {:error, "a weekly schedule needs a weekday" <> _} = Schedules.save(%{"name" => "w", "every" => "weekly", "hour" => 9})
      assert {:error, "a webhook is an http(s) URL"} = Schedules.save(%{"name" => "w", "every" => "daily", "hour" => 9, "webhook" => "file:///etc/passwd"})

      {:ok, s} = Schedules.save(%{"name" => "Marginalia daily", "every" => "daily", "hour" => 9, "options" => %{"apps" => ["marginalia"], "sections" => ["summary", "beam", "nope"]}, "webhook" => "https://hooks.example/x", "by" => "bg"})
      assert s.options == %{"apps" => ["marginalia"], "sections" => ["summary", "beam"]}
      assert is_integer(s.next_at)

      me = self()
      post = fn url, body -> send(me, {:posted, url, body}); :ok end
      instant = System.system_time(:millisecond)
      {:ok, saved} = Schedules.run(s, instant, post: post, base_url: "https://f.test")
      assert saved.url == "https://f.test/w/#{saved.slug}.md"
      assert_received {:posted, "https://hooks.example/x", %{title: "Marginalia daily: " <> _, url: url, text: text}}
      assert url == saved.url and text =~ saved.url

      {:ok, title, md} = Writeup.fetch(saved.slug)
      assert title =~ "Marginalia daily"
      assert md =~ "only marginalia" and md =~ "## The BEAM" and not (md =~ "## Incidents")
      assert {:ok, [%{last_slug: slug, last_error: nil, last_run_at: at}]} = Schedules.list()
      assert slug == saved.slug and at == instant
      assert {:ok, [%{by: "schedule: Marginalia daily"}]} = Writeup.list()
    end

    test "a webhook that fails is recorded on the schedule; the writeup is still saved" do
      {:ok, s} = Schedules.save(%{"name" => "x", "every" => "daily", "hour" => 9, "webhook" => "https://hooks.example/down"})
      assert {:error, "written, but the webhook failed: answered 500"} = Schedules.run(s, System.system_time(:millisecond), post: fn _, _ -> {:error, "answered 500"} end)
      assert {:ok, [%{last_error: "written, but the webhook failed: answered 500", last_slug: slug}]} = Schedules.list()
      assert is_binary(slug)
    end
  end
end

defmodule ObsFactorWeb.TokensSchedulesChannelTest do
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.Tape

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS api_tokens, writeup_schedules, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({ObsFactor.Objectives, db: db})
    start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)
    :ok
  end

  test "over the channel: a token made and listed, a schedule saved and run now" do
    {:ok, _, socket} = subscribe_and_join(authed_socket("a"), ObsFactorWeb.TapeChannel, "tape")
    ref = push(socket, "create_token", %{"name" => "ci", "by" => "a"})
    assert_reply ref, :ok, %{token: %{token: "obsf_" <> _}}
    assert_push "api_tokens", %{tokens: [%{name: "ci"}]}

    ref = push(socket, "save_schedule", %{"name" => "daily", "every" => "daily", "hour" => 7})
    assert_reply ref, :ok, %{schedule: %{id: id}}
    assert_push "schedules", %{schedules: [%{id: ^id}]}
    ref = push(socket, "run_schedule", %{"id" => id})
    assert_reply ref, :ok, %{writeup: %{slug: _}}, 5_000
  end
end
