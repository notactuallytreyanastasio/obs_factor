defmodule ObsFactorWeb.TapeChannelTest do
  @moduledoc """
  What the timeline (timeline.js) and the Fires panel (fires.js) rely on:
  the `tape` channel against a real store, as ObsFactor.TapeTest.
  """
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.Tape

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({ObsFactor.Objectives, db: db})
    start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
    Process.sleep(200)
    :ok
  end

  defp snap(n), do: %{at: "t#{n}", attention: [%{node: "app", severity: "alert", text: "x#{n}"}], nodes: [%{id: "app", kind: "app", status: "down", hosts: []}]}

  test "join gives the range; each frame written is a tick; a frame, the index, marks and insights answer" do
    {:ok, %{range: %{frames: 0}, tick_ms: _, windows: []}, socket} = subscribe_and_join(authed_socket("a"), ObsFactorWeb.TapeChannel, "tape")
    t0 = System.system_time(:millisecond) - 60_000

    for i <- 0..2 do
      s = snap(i)
      Tape.record(t0 + i * 5_000, Jason.encode!(s), Tape.summary(s))
      at = t0 + i * 5_000
      assert_push "tick", %{at: ^at, alerts: 1, down: 1, fires: 1}
    end

    ref = push(socket, "frame", %{"at" => t0 + 7_000})
    assert_reply ref, :ok, %{at: at, next: next, snapshot: frag}
    assert at == t0 + 5_000 and next == t0 + 10_000
    assert %{"at" => "t1"} = frag |> Jason.encode!() |> Jason.decode!()

    ref = push(socket, "index", %{"from" => t0, "to" => t0 + 15_000, "buckets" => 3})
    assert_reply ref, :ok, %{buckets: [[_, 1, 1, 0, 1, nil, nil], _, _]}

    ref = push(socket, "marks", %{"from" => t0, "to" => t0 + 15_000})
    assert_reply ref, :ok, %{marks: []}

    ref = push(socket, "insights", %{"from" => t0, "to" => t0 + 60_000})
    # the last frame burns on to the end of the window (now): 10 s + 50 s
    assert_reply ref, :ok, %{hot: [%{node: "app", alert_ms: 60_000}]}

    ref = push(socket, "save_window", %{"from" => t0, "to" => t0 + 10_000, "title" => "first two", "by" => "a"})
    # edges included: t0, +5 s, +10 s
    assert_reply ref, :ok, %{window: %{id: id, frames: 3}}
    assert_push "windows", %{windows: [%{id: ^id, title: "first two"}]}
    ref = push(socket, "lanes", %{"from" => t0, "to" => t0 + 15_000})
    assert_reply ref, :ok, %{lanes: [["app", "alert", ^t0, _, 3, "x2"]]}
    ref = push(socket, "prune_windows", %{"ids" => [id]})
    assert_reply ref, :ok, %{pruned: [^id]}
    # pruned, still listed for an hour, restorable
    assert_push "windows", %{windows: [%{id: ^id, pruned_at: p}]} when is_integer(p)
    ref = push(socket, "restore_windows", %{"ids" => [id]})
    assert_reply ref, :ok, %{restored: [^id]}
    assert_push "windows", %{windows: [%{id: ^id, pruned_at: nil}]}

    ref = push(socket, "insights", %{"from" => t0, "to" => t0 - 1})
    assert_reply ref, :error, %{error: "a window is" <> _}
  end
end
