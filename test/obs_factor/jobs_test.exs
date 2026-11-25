defmodule ObsFactor.JobsTest do
  @moduledoc """
  Oban in the observer (`ObsFactor.Jobs`): the migration, the workers, the
  Oban tab's view and its channel, against a real Postgres (as
  ObsFactor.TokensSchedulesTest). Oban runs in `testing: :manual`: jobs are
  inserted and performed by the test, nothing runs by itself.
  """
  use ObsFactorWeb.ChannelCase, async: false
  use Oban.Testing, repo: ObsFactor.Repo

  @moduletag :capture_log

  alias ObsFactor.{Alerts, Jobs, Repo, Tape}
  alias ObsFactor.Jobs.{Rollup, ScheduledWriteup, ScheduleTick, View, Webhook}
  alias ObsFactor.Writeup.Schedules

  @url System.get_env(
         "OBJECTIVES_TEST_PG_URL",
         "postgres://postgres:postgres@localhost/obs_factor_test"
       )
  @viewer %{"login" => "vera", "role" => "viewer", "via" => "github"}

  # every test migrates a fresh database: the migration file is loaded again
  setup_all do
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, false) end)
  end

  setup do
    db = Tape.db()

    start_supervised!(
      Supervisor.child_spec(
        {Postgrex,
         ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")},
        id: db
      )
    )

    Postgrex.query!(
      db,
      "DROP TABLE IF EXISTS oban_jobs, oban_peers, schema_migrations, alert_routes, tape_rollups, api_tokens, writeup_schedules, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives CASCADE",
      []
    )

    Postgrex.query!(db, "DROP TYPE IF EXISTS oban_job_state CASCADE", [])

    start_supervised!({Repo, Jobs.repo_opts(@url)})
    start_supervised!(ObsFactor.Jobs.Migrate)
    start_supervised!({Oban, Jobs.config(testing: :manual)})
    start_supervised!({ObsFactor.Objectives, db: db})
    start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)
    on_exit(fn -> Application.delete_env(:obs_factor, :webhook_post) end)
    %{db: db}
  end

  test "the migration made Oban's tables, and Oban runs on them" do
    assert {:ok, %{rows: [[1]]}} =
             Repo.query("SELECT 1 FROM pg_tables WHERE tablename = 'oban_jobs'")

    assert Jobs.enabled?()
    assert {:ok, %Oban.Job{}} = Jobs.insert(Rollup.new(%{}))
  end

  describe "scheduled writeups" do
    test "the tick enqueues a due schedule once; the run writes it up and enqueues its webhook" do
      {:ok, s} =
        Schedules.save(%{
          "name" => "daily",
          "every" => "daily",
          "hour" => 0,
          "webhook" => "https://hooks.example/w"
        })

      # made two days ago: today's 00:00 is due
      Postgrex.query!(
        Tape.db(),
        "UPDATE writeup_schedules SET created_at = now() - interval '2 days'",
        []
      )

      assert {:ok, %{enqueued: [_]}} = perform_job(ScheduleTick, %{})

      # a second tick while the first run waits: the same (schedule, instant) is not enqueued again
      assert {:ok, %{enqueued: []}} = perform_job(ScheduleTick, %{})

      assert [%{args: %{"id" => id, "instant" => instant}}] =
               all_enqueued(worker: ScheduledWriteup)

      assert id == s.id

      assert {:ok, %{slug: slug}} = perform_job(ScheduledWriteup, %{id: id, instant: instant})

      assert {:ok, [%{last_slug: ^slug, last_run_at: ^instant, last_error: nil}]} =
               Schedules.list()

      assert [
               %{
                 args: %{
                   "for" => "schedule",
                   "ref" => ^id,
                   "url" => "https://hooks.example/w",
                   "body" => %{"url" => url}
                 }
               }
             ] = all_enqueued(worker: Webhook)

      assert url =~ slug

      # ran, so not due again
      assert {:ok, %{enqueued: []}} = perform_job(ScheduleTick, %{})
    end

    test "a schedule deleted before its run cancels the job" do
      assert {:cancel, "no schedule 999"} = perform_job(ScheduledWriteup, %{id: 999, instant: 0})
    end
  end

  describe "webhooks" do
    setup do
      {:ok, r} = Alerts.save(%{"name" => "ops", "url" => "https://hooks.example/ops"})
      %{route: r}
    end

    test "a failure is retried, and recorded on the route only after the last attempt", %{
      route: r
    } do
      Application.put_env(:obs_factor, :webhook_post, fn _, _ -> {:error, "answered 503"} end)

      args = %{
        url: "https://hooks.example/ops",
        body: %{text: "x", items: []},
        for: "alert",
        ref: r.id
      }

      assert {:error, "answered 503"} = perform_job(Webhook, args, attempt: 1)
      assert {:ok, [%{last_error: nil}]} = Alerts.list()
      assert {:error, "answered 503"} = perform_job(Webhook, args, attempt: 5)
      assert {:ok, [%{last_error: "answered 503 (5 tries)"}]} = Alerts.list()

      Application.put_env(:obs_factor, :webhook_post, fn _, _ -> :ok end)
      assert :ok = perform_job(Webhook, args, attempt: 1)
      assert {:ok, [%{last_error: nil, last_sent_at: at}]} = Alerts.list()
      assert is_integer(at)
    end

    test "backoff: 5 s, 30 s, 2 min, 10 min" do
      assert for(n <- 1..5, do: Webhook.backoff(%Oban.Job{attempt: n})) == [5, 30, 120, 600, 600]
    end

    test "the alerts engine, with no post of its own, enqueues instead of posting", %{route: r} do
      start_supervised!(
        {ObsFactor.Alerts.Engine, db: Tape.db(), base_url: "https://f.test", flush_ms: 60_000}
      )

      ObsFactor.Objectives.observe(
        [%{node: "marginalia", severity: "alert", text: "marginalia down"}],
        %{"marginalia" => %{label: "Marginalia", status: "down"}}
      )

      _ = :sys.get_state(ObsFactor.Objectives)
      ObsFactor.Alerts.Engine.flush()
      assert [%{args: %{"for" => "alert", "ref" => ref}}] = all_enqueued(worker: Webhook)
      assert ref == r.id
    end
  end

  describe "the view" do
    setup do
      # completed in 200 ms after waiting 1 s; discarded after 3 errors; one scheduled
      {:ok, a} = Oban.insert(Rollup.new(%{}))
      {:ok, b} = Oban.insert(Webhook.new_post(:alert, 1, "https://hooks.example/x", %{text: "x"}))

      {:ok, c} =
        Oban.insert(
          Webhook.new(%{url: "https://hooks.example/y", body: %{text: "y"}, for: :alert, ref: 1},
            schedule_in: 3600
          )
        )

      Repo.query!(
        """
        UPDATE oban_jobs SET state = 'completed', attempt = 1,
          scheduled_at = timezone('UTC', now()) - interval '2 seconds',
          attempted_at = timezone('UTC', now()) - interval '1 second',
          completed_at = timezone('UTC', now()) - interval '800 milliseconds'
        WHERE id = $1
        """,
        [a.id]
      )

      err = fn n ->
        %{
          "attempt" => n,
          "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "error" => "** (RuntimeError) answered 500\n  stack"
        }
      end

      Repo.query!(
        """
        UPDATE oban_jobs SET state = 'discarded', attempt = 5, attempted_at = timezone('UTC', now()),
          discarded_at = timezone('UTC', now()), errors = $2
        WHERE id = $1
        """,
        [b.id, [err.(1), err.(2), err.(3)]]
      )

      %{a: a, b: b, c: c}
    end

    test "queues, states, minutes, workers, cron and jobs", %{a: a, b: b, c: c} do
      assert {:ok, v} = View.view()
      assert %{"completed" => 1, "discarded" => 1, "scheduled" => 1, "available" => 0} = v.states

      assert [
               %{name: "writeups"},
               %{name: "maintenance", completed: 1},
               %{name: "webhooks", discarded: 1, scheduled: 1}
             ] = v.queues

      assert length(v.minutes) == 60
      assert Enum.sum(Enum.map(v.minutes, &Enum.at(&1, 1))) == 1
      assert Enum.sum(Enum.map(v.minutes, &Enum.at(&1, 2))) == 1
      assert Enum.sum(Enum.map(v.minutes, &Enum.at(&1, 3))) == 3

      rollup = Enum.find(v.workers, &(&1.worker == "ObsFactor.Jobs.Rollup"))

      assert rollup.completed == 1 and rollup.p50 > 150 and rollup.p50 < 250 and
               rollup.wait_p95 > 900

      assert rollup.last == %{id: a.id, state: "completed", at: rollup.last.at}
      hook = Enum.find(v.workers, &(&1.worker == "ObsFactor.Jobs.Webhook"))
      assert hook.discarded == 1 and hook.retried == 1 and hook.pending == 1

      assert [
               %{expr: "* * * * *", worker: "ObsFactor.Jobs.ScheduleTick", next_at: n1},
               %{expr: "*/5 * * * *", worker: "ObsFactor.Jobs.Rollup", last: %{id: _}}
             ] = v.cron

      assert n1 > System.system_time(:millisecond) and
               n1 - System.system_time(:millisecond) <= 61_000

      assert Enum.map(v.jobs, & &1.id) == [c.id, b.id, a.id]
      assert Enum.find(v.jobs, &(&1.id == b.id)).error == "** (RuntimeError) answered 500"
      assert {:ok, [%{id: id}]} = View.jobs(%{"state" => "discarded"})
      assert id == b.id

      assert {:ok, [_, _]} =
               View.jobs(%{"worker" => "ObsFactor.Jobs.Webhook", "state" => "nonsense"})

      assert {:ok, j} = View.job(b.id)
      assert [%{attempt: 1, error: "** (RuntimeError) answered 500" <> _} | _] = j.errors
      assert j.args["url"] == "https://hooks.example/x"
      assert {:error, "no job 0"} = View.job(0)
    end

    test "over the channel: the view at join, a job, a filter; an operator retries, a viewer may not",
         %{b: b} do
      {:ok, v, socket} = subscribe_and_join(authed_socket("op"), ObsFactorWeb.JobsChannel, "jobs")
      assert length(v.jobs) == 3

      ref = push(socket, "job", %{"id" => b.id})
      assert_reply ref, :ok, %{job: %{id: _, errors: [_, _, _]}}
      ref = push(socket, "filter", %{"state" => "discarded"})
      assert_reply ref, :ok, %{jobs: [%{state: "discarded"}]}

      {:ok, _, vs} =
        subscribe_and_join(authed_socket("v", @viewer), ObsFactorWeb.JobsChannel, "jobs")

      for {ev, p} <- [
            {"retry", %{"id" => b.id}},
            {"cancel", %{"id" => b.id}},
            {"delete", %{"id" => b.id}},
            {"pause", %{"queue" => "webhooks"}},
            {"run_cron", %{"worker" => "ObsFactor.Jobs.Rollup"}}
          ] do
        ref = push(vs, ev, p)
        assert_reply ref, :error, %{error: "only an operator may " <> _}
      end

      ref = push(socket, "retry", %{"id" => b.id})
      assert_reply ref, :ok, %{ok: _}
      assert {:ok, %{state: "available"}} = View.job(b.id)

      ref = push(socket, "run_cron", %{"worker" => "ObsFactor.Jobs.Rollup"})
      assert_reply ref, :ok, %{ok: "enqueued ObsFactor.Jobs.Rollup"}
      ref = push(socket, "run_cron", %{"worker" => "ObsFactor.Jobs.Webhook"})
      assert_reply ref, :error, %{error: "ObsFactor.Jobs.Webhook is not on the crontab"}
      ref = push(socket, "pause", %{"queue" => "nope"})
      assert_reply ref, :error, %{error: "no queue \"nope\" here"}
    end
  end
end
