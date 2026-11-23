defmodule ObsFactor.WireFiltersTest do
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.{Tape, WireFilters}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({ObsFactor.Objectives, db: db})
    start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)
    :ok
  end

  test "a set is saved checked, renamed, listed by name, deleted" do
    {:ok, s} = WireFilters.save(%{"name" => " marginalia leaders ", "spec" => %{"apps" => ["marginalia"], "kinds" => ["leader", "partition"], "q" => " runs "}, "by" => "bg"})
    assert %{name: "marginalia leaders", by: "bg", spec: %{"apps" => ["marginalia"], "sevs" => [], "kinds" => ["leader", "partition"], "q" => "runs"}} = s
    {:ok, _} = WireFilters.save(%{"name" => "Alerts", "spec" => %{"sevs" => ["alert"]}})
    assert {:ok, [%{name: "Alerts"}, %{name: "marginalia leaders"}]} = WireFilters.list()
    {:ok, s2} = WireFilters.save(%{"id" => s.id, "name" => "leaders", "spec" => %{}})
    assert s2.id == s.id and s2.spec["apps"] == []
    assert {:error, "sevs are alert" <> _} = WireFilters.save(%{"name" => "x", "spec" => %{"sevs" => ["loud"]}})
    assert {:error, "a filter set needs a name"} = WireFilters.save(%{"name" => " ", "spec" => %{}})
    assert {:ok, _} = WireFilters.delete(s.id)
    assert {:error, "no filter set" <> _} = WireFilters.delete(s.id)
  end

  test "over the channel: in the join reply, saved and deleted for everyone" do
    {:ok, %{filters: []}, socket} = subscribe_and_join(authed_socket("a"), ObsFactorWeb.TapeChannel, "tape")
    ref = push(socket, "save_filter", %{"name" => "errors", "spec" => %{"kinds" => ["error", "failing"]}, "by" => "a"})
    assert_reply ref, :ok, %{filter: %{id: id}}
    assert_push "filters", %{filters: [%{id: ^id, name: "errors"}]}
    ref = push(socket, "delete_filter", %{"id" => id})
    assert_reply ref, :ok, %{deleted: ^id}
    assert_push "filters", %{filters: []}
  end
end
