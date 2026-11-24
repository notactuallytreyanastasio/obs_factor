defmodule ObsFactorWeb.IdentityChannelsTest do
  @moduledoc """
  Roles on the socket (ObsFactorWeb.Identity): the `action` event of an
  `observer:*` topic and the tape's operator writes refuse a viewer, on the
  server, whatever the page shows; what a viewer may do is signed with the
  login. Against a real Postgres for the tape (as ObsFactor.TokensSchedulesTest).
  """
  use ObsFactorWeb.ChannelCase, async: false

  @moduletag :capture_log

  alias ObsFactor.Tape

  @url System.get_env(
         "OBJECTIVES_TEST_PG_URL",
         "postgres://postgres:postgres@localhost/obs_factor_test"
       )
  @viewer %{"login" => "vera", "role" => "viewer", "via" => "github"}
  @operator %{"login" => "opal", "role" => "operator", "via" => "github"}

  setup do
    Application.put_env(:obs_factor, :observer_actions_token, "observer-actions")
    Application.put_env(:obs_factor, :observer_feed_intervals_ms, %{"proc" => 60_000})

    on_exit(fn ->
      Application.delete_env(:obs_factor, :observer_actions_token)
      Application.delete_env(:obs_factor, :observer_feed_intervals_ms)
    end)

    :ok
  end

  defp txt(pid), do: FactoryReport.Observer.pid_text(pid)

  describe "observer:* action" do
    test "a viewer is refused 403, the process lives, and the refusal is recorded with the login" do
      victim = spawn(fn -> receive(do: (:never -> :ok)) end)

      {:ok, %{}, _} =
        subscribe_and_join(authed_socket("w", @viewer), ObsFactorWeb.ActionsChannel, "actions")

      {:ok, _, socket} =
        subscribe_and_join(
          authed_socket("v", @viewer),
          ObsFactorWeb.FeedChannel,
          "observer:observer:-:proc:#{txt(victim)}"
        )

      ref =
        push(socket, "action", %{"path" => "proc/#{txt(victim)}/kill", "by" => "someone else"})

      assert_reply ref, :error, %{
        status: 403,
        error: "only an operator may act on a process (observer action); github:vera is a viewer"
      }

      assert_push "action", %{"by" => "vera", "status" => 403, "path" => "proc/" <> _}
      assert Process.alive?(victim)
    end

    test "a socket with no identity (a bare-sid token) is refused too" do
      victim = spawn(fn -> receive(do: (:never -> :ok)) end)

      {:ok, _, socket} =
        subscribe_and_join(
          authed_socket("n", nil),
          ObsFactorWeb.FeedChannel,
          "observer:observer:-:proc:#{txt(victim)}"
        )

      ref = push(socket, "action", %{"path" => "proc/#{txt(victim)}/kill", "by" => "anon"})
      assert_reply ref, :error, %{status: 403, error: "only an operator" <> _}
      assert Process.alive?(victim)
    end

    test "an operator acts, signed with the login" do
      victim = spawn(fn -> receive(do: (:never -> :ok)) end)

      {:ok, %{}, _} =
        subscribe_and_join(authed_socket("w", @operator), ObsFactorWeb.ActionsChannel, "actions")

      {:ok, _, socket} =
        subscribe_and_join(
          authed_socket("o", @operator),
          ObsFactorWeb.FeedChannel,
          "observer:observer:-:proc:#{txt(victim)}"
        )

      ref = push(socket, "action", %{"path" => "proc/#{txt(victim)}/gc", "by" => "someone else"})
      assert_reply ref, :ok, %{"ok" => true, "action" => "gc"}
      assert_push "action", %{"by" => "opal", "status" => 200}
    end
  end

  describe "tape" do
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
        "DROP TABLE IF EXISTS api_tokens, writeup_schedules, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives",
        []
      )

      start_supervised!({ObsFactor.Objectives, db: db})
      start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
      _ = :sys.get_state(Tape)
      :ok
    end

    test "create_token, revoke_token and the schedules are an operator's; a viewer is told so and nothing is made" do
      {:ok, _, v} =
        subscribe_and_join(authed_socket("v", @viewer), ObsFactorWeb.TapeChannel, "tape")

      ref = push(v, "create_token", %{"name" => "cron", "by" => "vera"})

      assert_reply ref, :error, %{
        error: "only an operator may make a script token; github:vera is a viewer"
      }

      assert {:ok, []} = ObsFactor.ApiTokens.list()

      sched = %{
        "name" => "daily",
        "every" => "daily",
        "hour" => 9,
        "options" => %{},
        "by" => "vera"
      }

      ref = push(v, "save_schedule", sched)

      assert_reply ref, :error, %{
        error: "only an operator may create or change a scheduled writeup" <> _
      }

      assert {:ok, []} = ObsFactor.Writeup.Schedules.list()

      ref = push(v, "revoke_token", %{"id" => 1})
      assert_reply ref, :error, %{error: "only an operator may revoke a script token" <> _}
      ref = push(v, "delete_schedule", %{"id" => 1})
      assert_reply ref, :error, %{error: "only an operator" <> _}
      ref = push(v, "run_schedule", %{"id" => 1})
      assert_reply ref, :error, %{error: "only an operator" <> _}

      {:ok, _, o} =
        subscribe_and_join(authed_socket("o", @operator), ObsFactorWeb.TapeChannel, "tape")

      ref = push(o, "create_token", %{"name" => "cron", "by" => "typed"})
      assert_reply ref, :ok, %{token: %{token: "obsf_" <> _, by: "opal"}}
      ref = push(o, "save_schedule", Map.put(sched, "by", "typed"))
      assert_reply ref, :ok, %{schedule: %{name: "daily"}}
      assert {:ok, [%{by: "opal"}]} = ObsFactor.Writeup.Schedules.list()
    end

    test "a viewer may still save a window and a filter set, signed with the login; a password login signs with the typed name" do
      {:ok, _, v} =
        subscribe_and_join(authed_socket("v", @viewer), ObsFactorWeb.TapeChannel, "tape")

      to = System.system_time(:millisecond)

      ref =
        push(v, "save_window", %{
          "from" => to - 60_000,
          "to" => to,
          "title" => "look",
          "by" => "not vera"
        })

      assert_reply ref, :ok, %{window: %{by: "vera"}}

      ref =
        push(v, "save_filter", %{
          "name" => "errors",
          "spec" => %{"kinds" => ["error"]},
          "by" => "not vera"
        })

      assert_reply ref, :ok, %{filter: %{by: "vera"}}

      # authed_socket's default: the password, an operator, no login
      {:ok, _, p} = subscribe_and_join(authed_socket("p"), ObsFactorWeb.TapeChannel, "tape")
      ref = push(p, "create_token", %{"name" => "glass", "by" => "dave"})
      assert_reply ref, :ok, %{token: %{by: "dave"}}
    end
  end
end
