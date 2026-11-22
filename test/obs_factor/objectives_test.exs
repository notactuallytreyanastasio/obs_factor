defmodule ObsFactor.ObjectivesTest do
  @moduledoc """
  Against a real Postgres: OBJECTIVES_TEST_PG_URL, or the local default
  postgres://postgres:postgres@localhost/obs_factor_test (created if it is
  not there). Skipped, saying why, when there is no Postgres to talk to.
  """
  use ExUnit.Case, async: false

  alias ObsFactor.Objectives

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup_all do
    case ensure_database(@url) do
      :ok -> :ok
      {:error, why} -> {:skip, "no Postgres for objectives tests: #{why}"}
    end
  end

  setup do
    db = :"objectives_test_db_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 1, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS objective_events, objectives", [])
    name = :"objectives_test_#{System.unique_integer([:positive])}"
    topic = "objectives_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, topic)
    start_supervised!({Objectives, db: db, name: name, topic: topic})
    # the schema is created in handle_continue: wait for it
    {:ok, _} = Objectives.list(name) |> retry(name)
    %{s: name, db: db}
  end

  defp retry({:ok, _} = ok, _), do: ok
  defp retry(_, name), do: (Process.sleep(50); Objectives.list(name))

  defp tick(s, attention, nodes \\ %{}) do
    Objectives.observe(attention, nodes, s)
    # a call after the cast: the cast has been handled
    {:ok, list} = Objectives.list(s)
    list
  end

  defp alert(node, text), do: %{node: node, severity: "alert", text: text}

  test "the same rule with other numbers is one objective, opened once, with the evidence of first sight", %{s: s} do
    nodes = %{"host-disk" => %{label: "Disk", status: "blocked", reason: "96% full", headline: %{value: 96, unit: "%"}, extra: :dropped}}
    [o] = tick(s, [alert("host-disk", "host disk 96% full")], nodes)
    [o2] = tick(s, [alert("host-disk", "host disk 97% full")], nodes)

    assert o.id == o2.id
    assert o.state == "open" and o.source == "rule" and o.seen_count == 1
    assert o.first_text == "host disk 96% full"
    assert o.evidence == %{"label" => "Disk", "status" => "blocked", "reason" => "96% full", "headline" => %{"value" => 96, "unit" => "%"}}
    assert [%{kind: "seen"}] = o.events
  end

  test "gone for a minute it clears itself; back again it reopens with the count", %{s: s} do
    [o] = tick(s, [alert("db", "Postgres connections 96 of 100")])
    # the grace is measured on the clock the cast carries: send a later tick
    GenServer.cast(s, {:observe, [], %{}, System.system_time(:millisecond) + 61_000})
    {:ok, [c]} = Objectives.list(s)
    assert c.id == o.id and c.state == "cleared" and c.cleared_at

    [b] = tick(s, [alert("db", "Postgres connections 97 of 100")])
    assert b.id == o.id and b.state == "open" and b.seen_count == 2 and b.cleared_at == nil
    assert Enum.map(b.events, & &1.kind) == ["seen", "cleared itself", "came back"]
  end

  test "looked at, then crossed off with a note: off the list of undone, a new sighting is a new objective", %{s: s} do
    [o] = tick(s, [alert("marginalia", "Marginalia: a lists b, which does not list it back")])
    {:ok, l} = Objectives.act(o.id, "look", %{"by" => "bg"}, s)
    assert l.state == "looking" and l.looking_by == "bg"

    {:ok, d} = Objectives.act(o.id, "done", %{"by" => "bg", "note" => "net split during deploy, healed"}, s)
    assert d.state == "done" and d.done_by == "bg" and d.note == "net split during deploy, healed"
    assert {:error, "cannot done an objective that is done"} = Objectives.act(o.id, "done", %{}, s)

    list = tick(s, [alert("marginalia", "Marginalia: a lists b, which does not list it back")])
    assert [%{state: "open", id: new}, %{state: "done", id: old}] = list
    assert new != old and old == o.id
    assert {:error, "this came back since" <> _} = Objectives.act(o.id, "reopen", %{}, s)
  end

  test "a pin is open until someone crosses it off, and never clears itself", %{s: s} do
    {:ok, p} = Objectives.pin(%{"node" => "blog", "title" => "  blog feels slow  ", "note" => "p99 up?", "by" => "bg"}, s)
    assert p.source == "pin" and p.title == "blog feels slow" and p.note == "p99 up?" and p.state == "open"

    GenServer.cast(s, {:observe, [], %{}, System.system_time(:millisecond) + 600_000})
    {:ok, [still]} = Objectives.list(s)
    assert still.state == "open"
    assert [%{kind: "pinned", by: "bg", note: "p99 up?"}] = still.events
  end

  test "a restarted server picks up where the last one left off", %{s: s, db: db} do
    [o] = tick(s, [alert("db", "Postgres down")])
    name = :"objectives_again_#{System.unique_integer([:positive])}"
    start_supervised!({Objectives, db: db, name: name}, id: :again)
    [again] = tick(name, [alert("db", "Postgres down")])
    assert again.id == o.id
  end

  test "no such objective, and nothing stored for one" do
    assert Objectives.key("db", "Postgres 96 of 100, 3.5 ms") == "db|Postgres # of #, # ms"
    assert Objectives.key(nil, "source docker failing") == "-|source docker failing"
  end

  test "every change is broadcast with the public row and its events", %{s: s} do
    [o] = tick(s, [alert("db", "Postgres connections 96 of 100")])
    assert_receive {:objective, %{id: id, state: "open", events: [%{kind: "seen"}]} = row}
    assert id == o.id and is_binary(row.opened_at)

    {:ok, _} = Objectives.act(o.id, "look", %{"by" => "bg"}, s)
    assert_receive {:objective, %{id: ^id, state: "looking", looking_by: "bg", events: [_, %{kind: "looking"}]}}

    GenServer.cast(s, {:observe, [], %{}, System.system_time(:millisecond) + 61_000})
    {:ok, _} = Objectives.list(s)
    assert_received {:objective, %{id: ^id, state: "cleared", events: [_, _, %{kind: "cleared itself"}]}}

    {:ok, _} = Objectives.act(o.id, "done", %{"by" => "bg", "note" => "fine"}, s)
    assert_receive {:objective, %{id: ^id, state: "done", note: "fine"}}

    {:ok, pin} = Objectives.pin(%{"node" => "blog", "title" => "odd", "by" => "bg"}, s)
    pin_id = pin.id
    assert_receive {:objective, %{id: ^pin_id, source: "pin", events: [%{kind: "pinned"}]}}
  end

  describe "the objectives channel" do
    import Phoenix.ChannelTest
    @endpoint ObsFactorWeb.Endpoint

    setup %{db: db} do
      start_supervised!(Supervisor.child_spec({Objectives, db: db}, id: :default_objectives))
      {:ok, _} = Objectives.list() |> retry(Objectives)
      socket = socket(ObsFactorWeb.UserSocket, "session:t", %{sid: "t"})
      %{socket: socket}
    end

    test "join replies with the list; a pin pushed by one viewer reaches every viewer", %{socket: socket} do
      {:ok, %{objectives: []}, a} = subscribe_and_join(socket, ObsFactorWeb.ObjectivesChannel, "objectives")

      ref = push(a, "pin", %{"node" => "blog", "title" => "looks wrong", "by" => "bg"})
      assert_reply ref, :ok, %{id: id, source: "pin", title: "looks wrong"}
      assert_push "objective", %{id: ^id, events: [%{kind: "pinned", by: "bg"}]}

      ref = push(a, "act", %{"id" => id, "action" => "look", "by" => "kim"})
      assert_reply ref, :ok, %{state: "looking"}
      assert_push "objective", %{id: ^id, state: "looking", looking_by: "kim"}

      ref = push(a, "act", %{"id" => "#{id}", "action" => "look"})
      assert_reply ref, :error, %{error: "act needs an integer id" <> _}

      {:ok, %{objectives: [%{id: ^id}]}, _} = subscribe_and_join(socket, ObsFactorWeb.ObjectivesChannel, "objectives")
    end
  end

  defp ensure_database(url) do
    uri = URI.parse(url)
    db = String.trim_leading(uri.path, "/")
    admin = %{uri | path: "/postgres"} |> URI.to_string()
    {:ok, pid} = Postgrex.start_link(ObsFactor.Postgres.opts(admin, name: nil, pool_size: 1, statement_timeout: "5000") |> Keyword.delete(:name) |> Keyword.put(:backoff_type, :stop))

    try do
      case Postgrex.query(pid, "SELECT 1 FROM pg_database WHERE datname = $1", [db]) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, _} -> Postgrex.query!(pid, ~s(CREATE DATABASE "#{db}"), []) && :ok
        {:error, e} -> {:error, Exception.message(e)}
      end
    catch
      :exit, reason -> {:error, inspect(reason)}
    after
      GenServer.stop(pid)
    end
  end
end
