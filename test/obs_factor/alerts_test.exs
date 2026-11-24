defmodule ObsFactor.AlertsTest do
  @moduledoc """
  Alerts that go out, against a real Postgres (as
  ObsFactor.TokensSchedulesTest) with a fake poster.
  """
  use ExUnit.Case, async: false

  alias ObsFactor.{Alerts, Objectives, Tape, WireFilters}
  alias ObsFactor.Alerts.Engine

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS alert_routes, api_tokens, writeup_schedules, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
    start_supervised!({Objectives, db: db})
    _ = :sys.get_state(Objectives)
    %{db: db}
  end

  describe "routes" do
    test "saved checked, listed without the URL, a blank URL keeps it, deleted", %{db: db} do
      assert {:error, "a route needs a name"} = Alerts.save(%{"url" => "https://hooks.example/a"})
      assert {:error, "a route needs a webhook URL"} = Alerts.save(%{"name" => "ops"})
      assert {:error, "10.1.2.3 is a private" <> _} = Alerts.save(%{"name" => "ops", "url" => "http://10.1.2.3/hook"})
      assert {:error, "quiet hours" <> _} = Alerts.save(%{"name" => "ops", "url" => "https://hooks.example/a", "quiet_from" => 22})
      assert {:error, "min_severity" <> _} = Alerts.save(%{"name" => "ops", "url" => "https://hooks.example/a", "min_severity" => "info"})

      {:ok, r} = Alerts.save(%{"name" => "ops", "url" => "https://hooks.slack.com/services/T0/B0/SECRETxyz9", "by" => "bg"})
      assert %{min_severity: "alert", apps: [], dedup_minutes: 15, enabled: true, url_hint: "https://hooks.slack.com/…xyz9", last_sent_at: nil} = r
      refute Map.has_key?(r, :url)
      refute inspect(Alerts.list()) =~ "SECRET"

      {:ok, r2} = Alerts.save(%{"id" => r.id, "name" => "ops night", "url" => "", "enabled" => false, "quiet_from" => 22, "quiet_to" => 7})
      assert %{name: "ops night", enabled: false, quiet_from: 22, quiet_to: 7, url_hint: "https://hooks.slack.com/…xyz9"} = r2
      assert {:ok, [%{url: "https://hooks.slack.com/services/T0/B0/SECRETxyz9"}]} = Alerts.routes(db)

      assert {:ok, _} = Alerts.delete(r.id)
      assert {:error, "no route" <> _} = Alerts.delete(r.id)
    end

    test "quiet hours wrap midnight" do
      at = fn h -> DateTime.to_unix(DateTime.new!(~D[2026-11-23], Time.new!(h, 30, 0)), :millisecond) end
      night = %{quiet_from: 22, quiet_to: 7}
      assert Alerts.quiet?(night, at.(23)) and Alerts.quiet?(night, at.(3))
      refute Alerts.quiet?(night, at.(7)) or Alerts.quiet?(night, at.(12))
      lunch = %{quiet_from: 12, quiet_to: 13}
      assert Alerts.quiet?(lunch, at.(12))
      refute Alerts.quiet?(lunch, at.(13))
      refute Alerts.quiet?(%{quiet_from: nil, quiet_to: nil}, at.(3))
    end
  end

  describe "the engine" do
    setup %{db: db} do
      me = self()
      # the fake webhook: tells the test, answers what the url says
      post = fn url, body ->
        send(me, {:posted, url, body})

        cond do
          url =~ "down" -> {:error, "answered 500"}
          url =~ "flaky" -> if(Process.get(:tried), do: :ok, else: (Process.put(:tried, true); {:error, "timeout"}))
          true -> :ok
        end
      end

      start_supervised!({Engine, db: db, post: post, base_url: "https://f.test", flush_ms: 60_000, retry_ms: 0})
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, Alerts.topic())
      :ok
    end

    test "an objective and a crash in one tick are one message; again within 15 min is nothing; crossed off resolves" do
      {:ok, ops} = Alerts.save(%{"name" => "ops", "url" => "https://hooks.example/ops"})

      tick(:objective_and_crash)
      assert_receive {:posted, "https://hooks.example/ops", body}
      refute_received {:posted, _, _}

      assert body.route == "ops"
      assert [obj, crash] = body.items
      assert %{state: "firing", severity: "alert", source: "objective", app: "marginalia", label: "Marginalia", title: "marginalia down"} = obj
      assert obj.building_url == "https://f.test/?scope=marginalia"
      assert obj.replay_url =~ ~r"^https://f.test/\?t=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"
      assert %{source: "wire", kind: "crash", title: "container crashed and restarted"} = crash
      # the warning is not for an alert route
      refute Enum.any?(body.items, &(&1.severity == "warn"))
      IO.puts("\n--- the Slack text, as sent ---\n" <> body.text <> "\n---")
      assert body.text =~ "obs_factor: 2 firing"
      assert body.text =~ "*[ALERT]* Marginalia: marginalia down"
      assert body.text =~ "<https://f.test/?scope=marginalia|building>"

      # recorded on the route, by the delivery task
      assert_receive {:alert_routes, [%{id: id, last_sent_at: sent, last_error: nil, sent_count: 1}]}
      assert id == ops.id and is_integer(sent)

      # the same crash again: deduplicated
      wire([crash_item()])
      Engine.flush()
      refute_receive {:posted, _, _}, 100

      # crossed off: resolved, to the route that was told
      {:ok, [o]} = Objectives.list()
      {:ok, _} = Objectives.act(o.id, "done", %{"by" => "bg", "note" => "restarted it"})
      _ = :sys.get_state(Objectives)
      Engine.flush()
      assert_receive {:posted, _, %{items: [%{state: "resolved", title: "marginalia down", detail: "crossed off by bg: restarted it"}], text: text}}
      assert text =~ "obs_factor: 1 resolved" and text =~ "*[RESOLVED]*"
    end

    test "a restarted engine does not fire on a flush; crossed off before it went out, nothing goes out" do
      {:ok, _} = Alerts.save(%{"name" => "ops", "url" => "https://hooks.example/ops"})
      old = DateTime.utc_now() |> DateTime.add(-40, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      # what Objectives broadcasts every 30 s while a rule still sees it
      Phoenix.PubSub.broadcast(ObsFactor.PubSub, "objectives",
        {:objective, %{id: 41, key: "x|disk #% full", source: "rule", node: "x", severity: "alert", title: "disk 96% full", state: "open",
                       seen_count: 1, evidence: nil, events: [%{at: old, kind: "seen", by: nil, note: nil}]}})

      Engine.flush()
      refute_receive {:posted, _, _}, 100

      Objectives.observe([%{node: "marginalia", severity: "alert", text: "marginalia down"}], %{})
      _ = :sys.get_state(Objectives)
      {:ok, [o]} = Objectives.list()
      {:ok, _} = Objectives.act(o.id, "done", %{"by" => "bg"})
      _ = :sys.get_state(Objectives)
      Engine.flush()
      refute_receive {:posted, _, _}, 100
    end

    test "per route: warnings, apps, a wire filter set, quiet hours, disabled" do
      {:ok, set} = WireFilters.save(%{"name" => "partitions", "spec" => %{"kinds" => ["partition"]}})
      h = System.system_time(:millisecond) |> div(3_600_000) |> rem(24)
      {:ok, _} = Alerts.save(%{"name" => "warn", "url" => "https://hooks.example/warn", "min_severity" => "warn"})
      {:ok, _} = Alerts.save(%{"name" => "blog", "url" => "https://hooks.example/blog", "apps" => ["blog"]})
      {:ok, _} = Alerts.save(%{"name" => "part", "url" => "https://hooks.example/part", "filter_id" => set.id})
      {:ok, _} = Alerts.save(%{"name" => "quiet", "url" => "https://hooks.example/quiet", "quiet_from" => h, "quiet_to" => rem(h + 1, 24)})
      {:ok, _} = Alerts.save(%{"name" => "off", "url" => "https://hooks.example/off", "enabled" => false})

      tick(:objective_and_crash)
      got = collect()

      assert Map.keys(got) |> Enum.sort() == ["https://hooks.example/part", "https://hooks.example/warn"]
      assert Enum.map(got["https://hooks.example/warn"].items, & &1.severity) == ["alert", "alert", "warn"]
      # the filter set narrows the wire, not the objectives
      assert Enum.map(got["https://hooks.example/part"].items, & &1.source) == ["objective"]
    end

    test "a failure is retried once and recorded; a flaky hook that answers the second time is a send" do
      {:ok, _} = Alerts.save(%{"name" => "down", "url" => "https://hooks.example/down"})
      wire([crash_item()])
      Engine.flush()
      assert_receive {:posted, _, _}
      assert_receive {:posted, _, _}
      assert_receive {:alert_routes, [%{last_error: "answered 500 (twice)", last_sent_at: nil}]}

      {:ok, _} = Alerts.save(%{"name" => "flaky", "url" => "https://hooks.example/flaky", "apps" => ["blog"]})
      wire([%{crash_item() | app: "blog", member: "blog@1"}])
      Engine.flush()
      assert_receive {:alert_routes, routes}
      assert %{last_error: nil, sent_count: 1} = Enum.find(routes, &(&1.name == "flaky"))
    end

    test "a test send goes out whatever the filters, and is recorded", %{db: db} do
      {:ok, r} = Alerts.save(%{"name" => "quiet", "url" => "https://hooks.example/t", "enabled" => false, "apps" => ["none"]})
      me = self()
      assert :ok = Alerts.test_send(r.id, db: db, base_url: "https://f.test", post: fn u, b -> send(me, {:posted, u, b}); :ok end)
      assert_receive {:posted, "https://hooks.example/t", %{text: "obs_factor: test\n*[TEST]* a test message from obs_factor" <> _}}
      assert {:ok, [%{sent_count: 1}]} = Alerts.list()
      assert {:error, "no route 999"} = Alerts.test_send(999, db: db)
    end
  end

  # ---- helpers ----------------------------------------------------------------

  defp crash_item,
    do: %{at: System.system_time(:millisecond), app: "marginalia", label: "Marginalia", member: "marginalia@1", kind: "crash", sev: "alert",
          head: "container crashed and restarted", text: "restart 3: the restart policy brought it back after 2h up"}

  defp wire(items), do: Phoenix.PubSub.broadcast(ObsFactor.PubSub, Tape.topic(), {:tape_frame, %{at: System.system_time(:millisecond), wire: items}})

  # what one tick says: an alert objective (through the real Objectives), a
  # crash and a warning on the wire
  defp tick(:objective_and_crash) do
    Objectives.observe([%{node: "marginalia", severity: "alert", text: "marginalia down"}], %{"marginalia" => %{label: "Marginalia", status: "down"}})
    _ = :sys.get_state(Objectives)
    wire([crash_item(), %{crash_item() | kind: "atoms", sev: "warn", head: "atoms +12k"}])
    Engine.flush()
  end

  defp collect(acc \\ %{}) do
    receive do
      {:posted, url, body} -> collect(Map.put(acc, url, body))
    after
      300 -> acc
    end
  end
end

defmodule ObsFactorWeb.AlertsChannelTest do
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.Tape

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS alert_routes, wire_filters, tape_wire, tape_windows, tape_frames", [])
    start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
    _ = :sys.get_state(Tape)
    on_exit(fn -> Application.delete_env(:obs_factor, :alert_allow_private_hosts) end)
    :ok
  end

  test "over the channel: a route saved, listed to everyone, test-sent to a real socket, deleted" do
    {:ok, reply, socket} = subscribe_and_join(authed_socket("a"), ObsFactorWeb.AlertsChannel, "alerts")
    assert %{routes: [], dedup_minutes: 15, allow_private: false} = reply

    ref = push(socket, "save_route", %{"name" => "lan", "url" => "http://127.0.0.1:9/"})
    assert_reply ref, :error, %{error: "127.0.0.1 is a private" <> _}

    # a receiver on this machine, allowed by ALERT_ALLOW_PRIVATE_HOSTS
    Application.put_env(:obs_factor, :alert_allow_private_hosts, true)
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    me = self()

    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(l, 5_000)
      {:ok, req} = :gen_tcp.recv(s, 0, 2_000)
      send(me, {:http, req})
      :gen_tcp.send(s, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
      :gen_tcp.close(s)
    end)

    ref = push(socket, "save_route", %{"name" => "lan", "url" => "http://127.0.0.1:#{port}/hook", "by" => "a"})
    assert_reply ref, :ok, %{route: %{id: id, url_hint: "http://127.0.0.1/…hook"}}
    assert_push "routes", %{routes: [%{id: ^id}]}

    ref = push(socket, "test_route", %{"id" => id})
    assert_reply ref, :ok, %{sent: true}, 5_000
    assert_receive {:http, req}
    assert req =~ "POST /hook"
    assert_push "routes", %{routes: [%{id: ^id, sent_count: 1, last_error: nil}]}

    ref = push(socket, "delete_route", %{"id" => id})
    assert_reply ref, :ok, %{deleted: ^id}
    assert_push "routes", %{routes: []}
  end
end
