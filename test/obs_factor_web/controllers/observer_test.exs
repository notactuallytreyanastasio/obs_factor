defmodule ObsFactorWeb.ObserverTest do
  # Shares the application's topology, Sources and LogRing.
  use ObsFactorWeb.ConnCase, async: false

  # Every action is logged at warning: kept off the console.
  @moduletag :capture_log

  @password "correct horse battery staple"
  @token "observer-actions"

  setup %{conn: conn} do
    conn = conn |> post("/login", %{"password" => @password}) |> recycle()
    on_exit(fn -> Application.delete_env(:obs_factor, :observer_actions_token) end)
    {:ok, conn: conn}
  end

  defp txt(pid), do: FactoryReport.Observer.pid_text(pid)

  defp actions_on, do: Application.put_env(:obs_factor, :observer_actions_token, @token)

  defp act(conn, path, body, by \\ "test (floor)") do
    conn = if by, do: put_req_header(conn, "x-factory-by", by), else: conn
    conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  end

  defp action_logged?(fragment) do
    Enum.any?(ObsFactor.LogRing.recent(2000, :warning), &(&1.attrs[:source] == "actions" and &1.text =~ fragment))
  end

  # A topology whose node "app" reports at a FactoryReport listening here.
  defp upstream(opts \\ []) do
    start_supervised!({FactoryReport, Keyword.merge([app: :obs_factor, port: 0, actions_token: @token], opts)})
    port = FactoryReport.port()
    original = ObsFactor.topology()
    on_exit(fn -> ObsFactor.put_topology(original) end)

    nodes =
      Enum.map(original.nodes, fn
        %{id: "app"} = n -> %{n | report: "http://127.0.0.1:#{port}/report"}
        n -> n
      end)

    ObsFactor.put_topology(%{original | nodes: nodes})
    port
  end

  defp members(addrs) do
    ObsFactor.Sources.put(:reports, %{
      ok: true,
      at: DateTime.utc_now(),
      error: nil,
      data: %{"app" => %{ok: true, members: Enum.map(addrs, &%{address: &1, ok: true})}},
      attempted_at: System.system_time(:millisecond),
      max_age_ms: 60_000
    })

    on_exit(fn -> ObsFactor.Sources.clear() end)
  end

  describe "the observer's own VM (node id observer)" do
    test "needs the session", %{conn: _} do
      conn = build_conn() |> get("/api/nodes/observer/observer/system")
      assert conn.status == 401
    end

    test "reads: index, system, apps, tree, procs, proc, ets, ports", %{conn: conn} do
      index = conn |> get("/api/nodes/observer/observer") |> json_response(200)
      assert index["proxy"] == %{"actions" => false}
      assert "tree/:app" in index["reads"]

      sys = conn |> get("/api/nodes/observer/observer/system") |> json_response(200)
      assert sys["node"] == to_string(node()) and is_number(sys["took_ms"])

      apps = conn |> get("/api/nodes/observer/observer/apps") |> json_response(200)
      assert Enum.find(apps["apps"], &(&1["name"] == "obs_factor"))["top_supervisor"] == txt(Process.whereis(ObsFactor.Supervisor))

      tree = conn |> get("/api/nodes/observer/observer/tree/obs_factor") |> json_response(200)
      assert tree["tree"]["registered_name"] == "ObsFactor.Supervisor"
      assert Enum.any?(tree["tree"]["children"], &(&1["id"] == "ObsFactor.Store"))

      procs = conn |> get("/api/nodes/observer/observer/procs?sort=memory&limit=3") |> json_response(200)
      assert length(procs["procs"]) == 3 and procs["sort"] == "memory"

      store = txt(Process.whereis(ObsFactor.Store))
      proc = conn |> get("/api/nodes/observer/observer/proc/#{store}") |> json_response(200)
      assert proc["registered_name"] == "ObsFactor.Store"
      assert proc["application"] == "obs_factor"
      assert proc["state"] == %{"status" => "not requested"}

      assert conn |> get("/api/nodes/observer/observer/ets") |> json_response(200) |> Map.has_key?("tables")
      assert conn |> get("/api/nodes/observer/observer/ports") |> json_response(200) |> Map.has_key?("ports")

      assert %{"error" => "pid 4.1.0 is not on this node" <> _} = conn |> get("/api/nodes/observer/observer/proc/4.1.0") |> json_response(400)
    end

    test "actions are off without OBSERVER_ACTIONS_TOKEN", %{conn: conn} do
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      body = conn |> act("/api/nodes/observer/observer/proc/#{txt(victim)}/kill", %{}) |> json_response(403)
      assert body["error"] == "actions are off: OBSERVER_ACTIONS_TOKEN is not set on the observer"
      assert Process.alive?(victim)
      assert action_logged?("proc/#{txt(victim)}/kill on observer by test (floor): 403")
    end

    test "an action needs to say who", %{conn: conn} do
      actions_on()
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      body = conn |> act("/api/nodes/observer/observer/proc/#{txt(victim)}/kill", %{}, nil) |> json_response(400)
      assert body["error"] =~ "say who is acting"
      assert Process.alive?(victim)
    end

    test "kill, gc and exit on a throwaway process, each logged with source actions", %{conn: conn} do
      actions_on()
      victim = spawn(fn -> Process.flag(:trap_exit, true); receive(do: (:never -> :ok)) end)

      assert %{"ok" => true, "memory_after" => _} = conn |> act("/api/nodes/observer/observer/proc/#{txt(victim)}/gc", %{}) |> json_response(200)
      assert %{"alive_after" => true} = conn |> act("/api/nodes/observer/observer/proc/#{txt(victim)}/exit", %{"reason" => "shutdown"}) |> json_response(200)
      assert %{"alive_after" => false} = conn |> act("/api/nodes/observer/observer/proc/#{txt(victim)}/kill", %{"by" => "ignored, the header wins"}) |> json_response(200)
      refute Process.alive?(victim)

      assert action_logged?("proc/#{txt(victim)}/gc on observer by test (floor): ok")
      assert action_logged?("proc/#{txt(victim)}/exit reason=\"shutdown\" on observer by test (floor): ok")
      assert action_logged?("proc/#{txt(victim)}/kill on observer by test (floor): ok")
    end

    test "every action, done or refused, is broadcast on the actions topic", %{conn: conn} do
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, "actions")
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      v = txt(victim)

      conn |> act("/api/nodes/observer/observer/proc/#{v}/kill", %{}) |> json_response(403)
      assert_receive {:action, %{"node" => "observer", "member" => nil, "path" => "proc/" <> _, "by" => "test (floor)", "status" => 403, "result" => nil, "error" => "actions are off" <> _, "at" => at}}
      assert {:ok, _, 0} = DateTime.from_iso8601(at)

      actions_on()
      conn |> act("/api/nodes/observer/observer/proc/#{v}/exit", %{"reason" => "shutdown"}, "dave") |> json_response(200)
      assert_receive {:action, %{"path" => "proc/" <> _, "params" => %{"reason" => "shutdown"}, "by" => "dave", "status" => 200, "error" => nil, "result" => %{"ok" => true, "action" => "exit"}}}

      conn |> act("/api/nodes/observer/observer/proc/#{v}/kill", %{}, nil) |> json_response(400)
      assert_receive {:action, %{"by" => nil, "status" => 400, "error" => "say who is acting" <> _}}
      assert action_logged?("proc/#{v}/kill on observer by nobody said: 400")

      # Reads are not actions.
      conn |> get("/api/nodes/observer/observer/system") |> json_response(200)
      refute_receive {:action, _}, 50
    end

    test "member= does not apply to the observer", %{conn: conn} do
      assert %{"error" => "the observer is one VM: member= does not apply to node observer"} =
               conn |> get("/api/nodes/observer/observer/system?member=10.0.0.1") |> json_response(400)
    end

    test "restart a child of the observer's own tree", %{conn: conn} do
      actions_on()
      sup = Process.whereis(ObsFactor.Supervisor)
      {id, old, _, _} = Enum.find(Supervisor.which_children(sup), fn {_, pid, _, _} -> pid == Process.whereis(ObsFactor.TaskSupervisor) end)

      body =
        conn
        |> act("/api/nodes/observer/observer/tree/obs_factor/restart", %{"supervisor" => txt(sup), "child_id" => inspect(id)}, "by body")
        |> json_response(200)

      assert body["old_pid"] == txt(old)
      assert body["new_pid"] == txt(Process.whereis(ObsFactor.TaskSupervisor))
      refute Process.alive?(old)
    end
  end

  describe "a building's VM, forwarded" do
    test "reads pass through to the report's host and port", %{conn: conn} do
      upstream()
      sys = conn |> get("/api/nodes/app/observer/system") |> json_response(200)
      assert sys["node"] == to_string(node())
      procs = conn |> get("/api/nodes/app/observer/procs?sort=memory&limit=2") |> json_response(200)
      assert procs["limit"] == 2 and procs["sort"] == "memory"
      # The upstream's own errors keep their status.
      assert %{"error" => "no started application \"nope\""} = conn |> get("/api/nodes/app/observer/tree/nope") |> json_response(404)
    end

    test "the report token goes with reads", %{conn: conn} do
      upstream(token: "read-token")
      assert %{"error" => "unauthorized"} = conn |> get("/api/nodes/app/observer/system") |> json_response(401)

      sources = Application.get_env(:obs_factor, :sources)
      Application.put_env(:obs_factor, :sources, Keyword.put(sources, :report_token, "read-token"))
      on_exit(fn -> Application.put_env(:obs_factor, :sources, sources) end)
      assert conn |> get("/api/nodes/app/observer/system") |> json_response(200)
    end

    test "actions carry OBSERVER_ACTIONS_TOKEN and who asked, and are logged here", %{conn: conn} do
      upstream()
      actions_on()
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      assert %{"ok" => true} = conn |> act("/api/nodes/app/observer/proc/#{txt(victim)}/kill", %{}, "carol") |> json_response(200)
      refute Process.alive?(victim)
      assert action_logged?("proc/#{txt(victim)}/kill on app by carol: ok")
      # The app logged it too, with the same who.
      assert Enum.any?(ObsFactor.LogRing.recent(2000, :warning), &(&1.text =~ "factory_report observer action: kill #{txt(victim)} by carol"))
    end

    test "a wrong token is the upstream's 401", %{conn: conn} do
      upstream(actions_token: "something-else")
      actions_on()
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      assert %{"error" => "unauthorized" <> _} = conn |> act("/api/nodes/app/observer/proc/#{txt(victim)}/kill", %{}) |> json_response(401)
      assert Process.alive?(victim)
    end

    test "a clustered node needs a member, and only a current one", %{conn: conn} do
      upstream()
      members(["127.0.0.1", "127.0.0.2"])

      assert %{"error" => "app has 2 members: say which with member= (127.0.0.1, 127.0.0.2)"} =
               conn |> get("/api/nodes/app/observer/system") |> json_response(400)

      assert %{"error" => "\"10.9.9.9\" is not one of app's current members (127.0.0.1, 127.0.0.2)"} =
               conn |> get("/api/nodes/app/observer/system?member=10.9.9.9") |> json_response(400)

      actions_on()
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, "actions")
      assert conn |> act("/api/nodes/app/observer/proc/#{txt(victim)}/kill?member=10.9.9.9", %{}) |> json_response(400)
      assert Process.alive?(victim)
      assert_receive {:action, %{"node" => "app", "member" => "10.9.9.9", "status" => 400}}

      assert %{"node" => _} = conn |> get("/api/nodes/app/observer/system?member=127.0.0.1") |> json_response(200)

      members([])

      assert %{"error" => "app is one node, not a cluster: member= does not apply"} =
               conn |> get("/api/nodes/app/observer/system?member=127.0.0.1") |> json_response(400)
    end

    test "unknown nodes, nodes without a report, an upstream that is down", %{conn: conn} do
      assert %{"error" => "no node \"nope\" in the topology"} = conn |> get("/api/nodes/nope/observer/system") |> json_response(404)
      assert %{"error" => "node caddy has no report URL, so no observer"} = conn |> get("/api/nodes/caddy/observer/system") |> json_response(404)

      # A port nothing listens on.
      {:ok, sock} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)
      original = ObsFactor.topology()
      on_exit(fn -> ObsFactor.put_topology(original) end)
      nodes = Enum.map(original.nodes, fn %{id: "app"} = n -> %{n | report: "http://127.0.0.1:#{port}/report"}; n -> n end)
      ObsFactor.put_topology(%{original | nodes: nodes})

      assert %{"error" => "127.0.0.1:" <> rest, "upstream_status" => nil} = conn |> get("/api/nodes/app/observer/system") |> json_response(502)
      assert rest =~ "connection refused"
    end

    test "path segments are checked", %{conn: conn} do
      assert %{"error" => "bad path segment" <> _} = conn |> get("/api/nodes/app/observer/proc/a%20b") |> json_response(400)
    end
  end
end
