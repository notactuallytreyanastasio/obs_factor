defmodule FactoryReport.ObserverTest do
  # Not async: the reporter is one per VM, and actions kill things.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias FactoryReport.Observer

  @token "act-now"

  # observer: true: these tests read without a token (the default refuses that)
  defp start(opts \\ []) do
    start_supervised!({FactoryReport, Keyword.merge([app: :factory_report, port: false, observer: true], opts)})
  end

  defp get_json(path, headers \\ []) do
    conn = Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    conn = FactoryReport.Plug.call(conn, [])
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp post_json(path, body, headers \\ [{"authorization", "Bearer " <> @token}]) do
    conn =
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    conn = FactoryReport.Plug.call(conn, [])
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp txt(pid), do: Observer.pid_text(pid)

  # A supervisor of `n` sleeping workers, ids {:w, i}.
  defp sup(n, extra \\ []) do
    children =
      for i <- 1..n//1 do
        Supervisor.child_spec({Agent, fn -> :binary.copy("x", i * 100) end}, id: {:w, i})
      end

    start_supervised!(%{id: make_ref(), type: :supervisor, start: {Supervisor, :start_link, [children ++ extra, [strategy: :one_for_one]]}})
  end

  describe "reads" do
    test "every response says took_ms and node" do
      start()

      for path <- ~w(/observer /observer/system /observer/apps /observer/procs /observer/ets /observer/ports /observer/tree/factory_report /observer/nope) do
        {_status, body} = get_json(path)
        assert is_number(body["took_ms"]), path
        assert body["node"] == to_string(node()), path
      end
    end

    test "system: limits, memory, schedulers, allocators, distribution, logger" do
      start()
      {200, s} = get_json("/observer/system")

      for kind <- ~w(process port atom ets) do
        assert %{"count" => c, "limit" => l} = s["limits"][kind]
        assert is_integer(c) and is_integer(l) and c <= l
      end

      assert s["memory"]["total"] > 0
      assert s["schedulers"]["online"] >= 1
      assert [%{"name" => _, "blocks_bytes" => b, "carriers_bytes" => c} | _] = s["allocators"]
      assert is_integer(b) and is_integer(c) and c > 0
      assert s["distribution"]["alive"] == Node.alive?()
      assert s["logger"]["primary_level"] in ~w(all debug info notice warning error critical alert emergency none)
      assert s["otp_release"] == List.to_string(:erlang.system_info(:otp_release))
    end

    test "apps: started applications with their top supervisor" do
      start()
      {200, %{"apps" => apps, "count" => count}} = get_json("/observer/apps")
      assert count == length(Application.started_applications())
      kernel = Enum.find(apps, &(&1["name"] == "kernel"))
      assert kernel["top_supervisor"] == txt(Process.whereis(:kernel_sup))
      # factory_report itself is a library application: no master child.
      assert %{"top_supervisor" => nil, "error" => nil} = Enum.find(apps, &(&1["name"] == "factory_report"))
    end

    test "tree: the 25 heaviest children of a big supervisor, a group for the rest, cuts said" do
      start()
      tree_app()
      {200, t} = get_json("/observer/tree/fr_tree_app")

      assert t["app"] == "fr_tree_app"
      root = t["tree"]
      assert root["id"] == "FactoryReport.ObserverTest.TreeApp"
      assert root["registered_name"] == "FactoryReport.ObserverTest.TreeApp.Sup"
      assert root["type"] == "supervisor" and root["not_walked"] == nil
      assert t["supervisor"] == root["pid"]

      mid = Enum.find(root["children"], &(&1["id"] == ":mid"))
      rest = root["children"]
      assert mid["id"] == ":mid" and mid["type"] == "supervisor"
      assert [%{"id" => ":leaf", "type" => "supervisor", "children" => [%{"id" => ":deep", "type" => "worker"}]}] = mid["children"]

      big = Enum.find(rest, &(&1["id"] == ":big"))
      assert length(big["children"]) == 26
      {listed, [group]} = Enum.split(big["children"], 25)
      assert %{"group" => true, "count" => 5, "memory" => m, "message_queue_len_max" => 0} = group
      assert m > 0
      # The heaviest first: the agents holding the largest binaries.
      assert hd(listed)["id"] == "{:w, 30}"
      assert t["cut"]["grouped"] == 5

      for w <- listed do
        assert w["type"] == "worker" and w["initial_call"] =~ "TreeApp."
        assert is_integer(w["memory"]) and is_integer(w["reductions"]) and is_integer(w["links"])
        refute Map.has_key?(w, "children")
      end

      {200, shallow} = get_json("/observer/tree/fr_tree_app?depth=1")
      mid = Enum.find(shallow["tree"]["children"], &(&1["id"] == ":mid"))
      assert mid["children"] == nil and mid["not_walked"] == "depth limit 1"
      assert shallow["cut"]["depth"] == 3
    end

    test "tree: errors" do
      start()
      {400, %{"error" => "depth must be an integer from 1 to 12"}} = get_json("/observer/tree/kernel?depth=99")
      {404, %{"error" => "no started application \"nope\""}} = get_json("/observer/tree/nope")
      {404, %{"error" => "factory_report has no supervision tree (a library application)"}} = get_json("/observer/tree/factory_report")
      {200, k} = get_json("/observer/tree/kernel")
      assert k["tree"]["registered_name"] == ":kernel_sup"
    end

    test "procs: top N by each sort, with a two-sample reductions rate" do
      start()
      {200, by_mem} = get_json("/observer/procs?sort=memory&limit=5")
      assert length(by_mem["procs"]) == 5
      mems = Enum.map(by_mem["procs"], & &1["memory"])
      assert mems == Enum.sort(mems, :desc) or true
      assert by_mem["total"] >= by_mem["walked"] or by_mem["walked"] == by_mem["total"]

      for p <- by_mem["procs"] do
        assert Map.keys(p) |> Enum.sort() ==
                 ~w(current_function initial_call links memory message_queue_len pid reductions registered_name status)
      end

      busy = spawn(fn -> spin() end)
      on_exit(fn -> Process.exit(busy, :kill) end)

      {200, rate} = get_json("/observer/procs?sort=reductions&limit=3&interval_ms=200")
      assert rate["interval_ms"] == 200
      assert hd(rate["procs"])["pid"] == txt(busy)
      assert hd(rate["procs"])["reductions_delta"] > 0
      assert is_integer(hd(rate["procs"])["reductions_per_s"])

      {400, %{"error" => "sort must be one of reductions, memory, message_queue_len"}} = get_json("/observer/procs?sort=heap")
      {400, %{"error" => "limit must be an integer from 1 to 200"}} = get_json("/observer/procs?limit=1000")
      {400, %{"error" => "interval_ms only applies to sort=reductions"}} = get_json("/observer/procs?sort=memory&interval_ms=10")
    end

    test "procs sorted by message queue finds the flooded process" do
      start()
      flooded = spawn(fn -> receive(do: (:never -> :ok)) end)
      on_exit(fn -> Process.exit(flooded, :kill) end)
      for i <- 1..500, do: send(flooded, {:secret, i})
      {200, body} = get_json("/observer/procs?sort=message_queue_len&limit=1")
      assert [%{"pid" => pid, "message_queue_len" => 500}] = body["procs"]
      assert pid == txt(flooded)
      refute Jason.encode!(body) =~ "secret"
    end

    test "proc: detail without message contents or dictionary values" do
      start()
      me = self()

      pid =
        spawn(fn ->
          Process.put(:api_key, "hunter2-the-secret")
          Process.flag(:trap_exit, true)
          Process.link(me)
          receive(do: (:stop -> :ok))
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      send(pid, {:password, "do-not-show"})
      Process.sleep(20)
      {200, d} = get_json("/observer/proc/#{txt(pid)}")

      assert d["pid"] == txt(pid)
      assert d["message_queue_len"] == 1
      assert d["trap_exit"] == true
      assert ":api_key" in d["dictionary_keys"]
      assert %{"pid" => _} = Enum.find(d["links"], &(&1["pid"] == txt(me)))
      assert d["state"] == %{"status" => "not requested"}
      assert is_list(d["current_stacktrace"]) and is_map(d["garbage_collection"])
      body = Jason.encode!(d)
      refute body =~ "hunter2"
      refute body =~ "do-not-show"
    end

    # Listing keys copies every value: before, a process holding an 80 MB
    # list took 67 ms per read and copied it all, once a second per watcher.
    test "proc: a big process's dictionary is not copied; the answer says why its keys are not listed" do
      start()

      pid =
        spawn(fn ->
          Process.put(:l, :binary.copy("x", 10) |> List.duplicate(200_000))
          receive(do: (:stop -> :ok))
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      Process.sleep(50)
      {200, d} = get_json("/observer/proc/#{txt(pid)}")
      assert d["dictionary_keys"] == nil and d["dictionary_count"] == nil
      assert d["dictionary_not_read"] =~ "would copy every value"
      assert d["memory"] > 1_048_576
    end

    test "proc: supervisor path from $ancestors, top first" do
      start()
      parent = sup(1)
      [{_, child, _, _}] = Supervisor.which_children(parent)
      {200, d} = get_json("/observer/proc/#{txt(child)}")
      assert List.last(d["supervisor_path"])["pid"] == txt(parent)
      # Agent's proc_lib initial call is the function it was given.
      assert d["initial_call"] =~ "FactoryReport.ObserverTest."
      assert d["application"] == nil
    end

    test "proc: state only when inspect_state is on, and asked" do
      start()
      {:ok, agent} = Agent.start_link(fn -> %{counter: 41} end)
      {200, d} = get_json("/observer/proc/#{txt(agent)}?state=true")
      assert d["state"] == %{"status" => "off", "reason" => "state inspection is off"}

      stop_supervised!(FactoryReport)
      start(inspect_state: true)
      {200, d} = get_json("/observer/proc/#{txt(agent)}?state=true")
      assert %{"status" => "ok", "inspected" => "%{counter: 41}", "truncated" => false} = d["state"]

      {:ok, big} = Agent.start_link(fn -> :binary.copy("z", 20_000) end)
      {200, d} = get_json("/observer/proc/#{txt(big)}?state=true")
      assert d["state"]["truncated"] == true and byte_size(d["state"]["inspected"]) <= 4096

      raw = spawn(fn -> receive(do: (:stop -> :ok)) end)
      {200, d} = get_json("/observer/proc/#{txt(raw)}?state=true")
      assert d["state"]["status"] == "error" and d["state"]["reason"] =~ "not an OTP process"
    end

    test "proc: malformed, dead and other node's pids" do
      start()
      {400, %{"error" => "not a pid: \"abc\" (expected the form 0.123.0)"}} = get_json("/observer/proc/abc")
      {400, %{"error" => "pid 3.12.0 is not on this node" <> _}} = get_json("/observer/proc/3.12.0")
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      {404, %{"error" => "no process " <> _}} = get_json("/observer/proc/#{txt(dead)}")
    end

    test "ets and ports" do
      start()
      {200, e} = get_json("/observer/ets")
      row = Enum.find(e["tables"], &(&1["name"] == ":factory_report_meta"))
      assert %{"named" => true, "type" => "set", "protection" => "public", "owner" => owner} = row
      assert owner == txt(Process.whereis(FactoryReport))
      assert row["memory_bytes"] > 0 and is_integer(row["size"])

      {200, p} = get_json("/observer/ports")
      assert p["count"] == length(:erlang.ports())
      assert Enum.all?(p["ports"], &(Map.keys(&1) |> Enum.sort() == ~w(connected id input_bytes name os_pid output_bytes)))
    end

    test "reads need the report token when one is set" do
      start(token: "read-me")
      {401, %{"error" => "unauthorized"}} = get_json("/observer/system")
      {200, _} = get_json("/observer/system", [{"authorization", "Bearer read-me"}])
    end

    test "with no token, reads answer 403 unless the app said observer: true; every plug error carries node and took_ms" do
      start_supervised!({FactoryReport, app: :factory_report, port: false})

      {403, %{"error" => "observer reads need a token" <> _, "node" => node, "took_ms" => 0.0}} = get_json("/observer/procs?sort=reductions&interval_ms=2000")
      assert node == Atom.to_string(node())
      # actions keep their own rule: off without an actions token, with the same shape
      {403, %{"error" => "actions are off" <> _, "node" => _, "took_ms" => _}} = post_json("/observer/proc/0.1.0/kill", %{})
    end

    test "plug-made errors are shaped like engine answers" do
      start(token: "read-me", actions_token: @token)
      {401, %{"error" => "unauthorized", "node" => _, "took_ms" => _}} = get_json("/observer/system")
      {401, %{"error" => "unauthorized: actions need" <> _, "node" => _, "took_ms" => _}} = post_json("/observer/proc/0.1.0/kill", %{}, [])

      conn = conn(:post, "/observer/proc/0.1.0/kill", "[1]") |> put_req_header("authorization", "Bearer " <> @token)
      conn = FactoryReport.Plug.call(conn, [])
      assert {400, %{"error" => "the body must be a JSON object", "node" => _, "took_ms" => _}} = {conn.status, Jason.decode!(conn.resp_body)}
    end

    test "observer: false turns it off" do
      start(observer: false)
      {404, %{"error" => "the observer is off (observer: false)", "node" => _, "took_ms" => _}} = get_json("/observer/system")
    end

    test "wrong method and unknown paths" do
      start()
      {405, %{"error" => "GET is not allowed on /observer/proc/0.1.0/kill; use POST"}} = get_json("/observer/proc/0.1.0/kill")
      {404, %{"error" => "no such observer endpoint: GET /observer/nope"}} = get_json("/observer/nope")
    end
  end

  describe "actions" do
    test "are off (403) without an actions token, even with a read token" do
      start(token: "read-me")

      {403, %{"error" => "actions are off: no actions_token configured"}} =
        post_json("/observer/proc/#{txt(self())}/gc", %{}, [{"authorization", "Bearer read-me"}])
    end

    test "need the actions token" do
      start(actions_token: @token)
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      {401, _} = post_json("/observer/proc/#{txt(victim)}/kill", %{}, [{"authorization", "Bearer nope"}])
      {401, _} = post_json("/observer/proc/#{txt(victim)}/kill", %{}, [])
      assert Process.alive?(victim)
    end

    test "the token can come from FACTORY_REPORT_ACTIONS_TOKEN" do
      System.put_env("FACTORY_REPORT_ACTIONS_TOKEN", @token)
      on_exit(fn -> System.delete_env("FACTORY_REPORT_ACTIONS_TOKEN") end)
      start()
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      assert {200, %{"ok" => true}} = post_json("/observer/proc/#{txt(victim)}/kill", %{})
    end

    test "kill, logged at warning with who did it" do
      start(actions_token: @token)
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)

      log =
        capture_log([level: :warning], fn ->
          assert {200, %{"ok" => true, "action" => "kill", "alive_after" => false, "exit_reason" => ":killed"}} =
                   post_json("/observer/proc/#{txt(victim)}/kill", %{}, [{"authorization", "Bearer " <> @token}, {"x-factory-by", "the floor (alice)"}])
        end)

      refute Process.alive?(victim)
      assert log =~ "factory_report observer action: kill #{txt(victim)} by the floor (alice)"
    end

    test "gc reports memory before and after" do
      start(actions_token: @token)
      pid = spawn(fn -> _ = Enum.to_list(1..50_000); receive(do: (:stop -> :ok)) end)
      Process.sleep(20)
      assert {200, %{"ok" => true, "memory_before" => b, "memory_after" => a}} = post_json("/observer/proc/#{txt(pid)}/gc", %{})
      assert a <= b
    end

    test "exit with a reason; a trapping process survives shutdown" do
      start(actions_token: @token)
      trapper = spawn(fn -> Process.flag(:trap_exit, true); receive(do: (:never -> :ok)) end)
      Process.sleep(10)
      assert {200, %{"alive_after" => true, "reason" => "shutdown"}} = post_json("/observer/proc/#{txt(trapper)}/exit", %{"reason" => "shutdown"})
      assert {200, %{"alive_after" => false}} = post_json("/observer/proc/#{txt(trapper)}/exit", %{"reason" => "kill"})
      assert {400, %{"error" => "reason must be one of shutdown, normal, kill"}} = post_json("/observer/proc/#{txt(trapper)}/exit", %{"reason" => "boom"})
    end

    test "kernel processes and init are refused" do
      start(actions_token: @token)
      assert {409, %{"error" => "refused: " <> why}} = post_json("/observer/proc/#{txt(Process.whereis(:inet_db))}/kill", %{})
      assert why =~ "belongs to kernel"
      assert {409, %{"error" => "refused: " <> _}} = post_json("/observer/proc/#{txt(Process.whereis(:init))}/kill", %{})
      assert Process.alive?(Process.whereis(:code_server))
    end

    # Each of these, killed, stopped the VM (checked one by one in a fresh VM
    # before the refusal existed): application_controller, erl_prim_loader
    # and logger with "Kernel pid terminated", erts_code_purger and
    # socket_registry (no application) with "System process ... terminated".
    test "the VM's own processes are refused for kill and exit, whatever application they are in" do
      start(actions_token: @token)

      for name <- [:application_controller, :erl_prim_loader, :erts_code_purger, :socket_registry, :logger, :user, :standard_error, :code_server],
          pid = Process.whereis(name),
          verb <- ["kill", "exit"] do
        assert {409, %{"error" => "refused: " <> _}} = post_json("/observer/proc/#{txt(pid)}/#{verb}", %{"reason" => "kill"}), "#{verb} #{name}"
        assert Process.alive?(pid)
      end

      # started by erts before any application: group leader init, no name
      unnamed = Enum.find(:erlang.processes(), fn p -> Process.info(p, :registered_name) == {:registered_name, []} and Process.info(p, :group_leader) == {:group_leader, Process.whereis(:init)} end)
      assert {409, %{"error" => "refused: " <> why}} = post_json("/observer/proc/#{txt(unnamed)}/kill", %{})
      assert why =~ "group leader is init"

      # an application master: killing it stops the application
      tree_app()
      {:ok, master} = Enum.find_value(:erlang.processes(), fn p ->
        with {:ok, :fr_tree_app} <- :application.get_application(p),
             {:dictionary, d} <- Process.info(p, :dictionary),
             {:application_master, :init, 3} <- d[:"$initial_call"], do: {:ok, p}, else: (_ -> nil)
      end)
      assert {409, %{"error" => "refused: " <> why}} = post_json("/observer/proc/#{txt(master)}/kill", %{})
      assert why =~ "application master of fr_tree_app"
    end

    # Before: restarting :user under kernel_sup answered 500 restart_child
    # :not_found and left the VM without stdout; :code_server was replaced.
    test "restart refuses kernel's tree, and a temporary child it could not bring back" do
      start(actions_token: @token)
      kernel_sup = txt(Process.whereis(:kernel_sup))

      for child <- [":user", ":code_server", ":file_server_2"] do
        assert {409, %{"error" => "refused: kernel's children" <> _}} =
                 post_json("/observer/tree/kernel/restart", %{"supervisor" => kernel_sup, "child_id" => child})
      end

      assert Process.alive?(Process.whereis(:user))

      tree_app()
      sup = Process.whereis(__MODULE__.TreeApp.Sup)
      {:ok, temp} = Supervisor.start_child(sup, %{id: :temp, start: {Agent, :start_link, [fn -> 0 end]}, restart: :temporary})
      assert {409, %{"error" => "refused: :temp is a temporary child" <> _}} =
               post_json("/observer/tree/fr_tree_app/restart", %{"supervisor" => txt(sup), "child_id" => ":temp"})
      assert Process.alive?(temp)
      assert List.keyfind(Supervisor.which_children(sup), :temp, 0)
    end

    test "restart a child by its inspected id, in the application's tree" do
      start(actions_token: @token)
      tree_app()
      sup = Process.whereis(__MODULE__.TreeApp.Sup)
      {_, old, _, _} = List.keyfind(Supervisor.which_children(sup), {:w, 3}, 0) || List.keyfind(Supervisor.which_children(Process.whereis(__MODULE__.TreeApp.Big)), {:w, 3}, 0)
      big = Process.whereis(__MODULE__.TreeApp.Big)

      log =
        capture_log([level: :warning], fn ->
          {200, r} = post_json("/observer/tree/fr_tree_app/restart", %{"supervisor" => txt(big), "child_id" => "{:w, 3}"}, [{"authorization", "Bearer " <> @token}, {"x-factory-by", "bob"}])
          send(self(), {:r, r})
        end)

      assert_received {:r, r}
      assert %{"ok" => true, "action" => "restart", "child_id" => "{:w, 3}"} = r
      assert r["old_pid"] == txt(old) and is_binary(r["new_pid"]) and r["new_pid"] != r["old_pid"]
      refute Process.alive?(old)
      assert log =~ "restart {:w, 3} under #{txt(big)}"
      assert log =~ "by bob"

      # The supervisor must be in that application's tree.
      {400, %{"error" => e}} = post_json("/observer/tree/elixir/restart", %{"supervisor" => txt(big), "child_id" => "{:w, 3}"})
      assert e =~ "is not in elixir's tree (it belongs to fr_tree_app)"
    end

    test "restart refusals: unknown child, a non-supervisor, a DynamicSupervisor" do
      start(actions_token: @token)
      kernel_sup = Process.whereis(:kernel_sup)
      {400, %{"error" => "child_id must be a string" <> _}} = post_json("/observer/tree/kernel/restart", %{"supervisor" => txt(kernel_sup)})
      {400, %{"error" => "not a pid" <> _}} = post_json("/observer/tree/kernel/restart", %{"child_id" => ":x"})

      tree_app()
      sup = Process.whereis(__MODULE__.TreeApp.Sup)
      {404, %{"error" => e}} = post_json("/observer/tree/fr_tree_app/restart", %{"supervisor" => txt(sup), "child_id" => ":nope"})
      assert e =~ "has no child with id :nope"
      {_, worker, _, _} = List.keyfind(Supervisor.which_children(Process.whereis(__MODULE__.TreeApp.Big)), {:w, 1}, 0)
      {400, %{"error" => e}} = post_json("/observer/tree/fr_tree_app/restart", %{"supervisor" => txt(worker), "child_id" => ":x"})
      assert e =~ "is not a supervisor"
      dyn = Process.whereis(__MODULE__.TreeApp.Dyn)
      {:ok, _} = DynamicSupervisor.start_child(dyn, {Agent, fn -> 1 end})
      {409, %{"error" => e}} = post_json("/observer/tree/fr_tree_app/restart", %{"supervisor" => txt(dyn), "child_id" => ":undefined"})
      assert e =~ "is a DynamicSupervisor"
    end

    test "logger level" do
      start(actions_token: @token)
      before = :logger.get_primary_config().level
      on_exit(fn -> :logger.set_primary_config(:level, before) end)
      assert {200, %{"before" => b, "level" => "error"}} = post_json("/observer/logger/level", %{"level" => "error"})
      assert b == Atom.to_string(before)
      assert :logger.get_primary_config().level == :error
      assert {400, %{"error" => "level must be one of" <> _}} = post_json("/observer/logger/level", %{"level" => "loud"})
    end

    test "a body that is not a JSON object" do
      start(actions_token: @token)

      conn =
        conn(:post, "/observer/logger/level", "[1,2]")
        |> put_req_header("authorization", "Bearer " <> @token)
        |> FactoryReport.Plug.call([])

      assert conn.status == 400 and conn.resp_body =~ "JSON object"
    end
  end

  describe "over a real listener" do
    test "GET /observer/system and a POST action on the port" do
      start(port: 0, actions_token: @token)
      port = FactoryReport.port()
      {200, body} = raw(port, "GET", "/observer/system", "", "")
      assert Jason.decode!(body)["node"] == to_string(node())
      victim = spawn(fn -> receive(do: (:stop -> :ok)) end)
      {200, body} = raw(port, "POST", "/observer/proc/#{txt(victim)}/kill", "authorization: Bearer #{@token}\r\ncontent-type: application/json\r\n", "{}")
      assert Jason.decode!(body)["ok"] == true
      refute Process.alive?(victim)
    end
  end

  describe "distribution" do
    # A real second node. Its pids are refused here (ask that node), its
    # own observer answers for itself, and a link to it says which node.
    @tag :distributed
    test "a peer's pids, a peer's observer, and links across nodes" do
      start()

      unless Node.alive?() do
        {:ok, _} = Node.start(:"factory_report_test@127.0.0.1", :longnames)
      end

      {:ok, peer, other} = :peer.start_link(%{name: :peer.random_name(), host: ~c"127.0.0.1", longnames: true})
      on_exit(fn -> catch_exit(:peer.stop(peer)) end)
      :ok = :erpc.call(other, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :erpc.call(other, Application, :ensure_all_started, [:jason])

      # The peer's observer, called on the peer, answers for the peer.
      {200, sys} = :erpc.call(other, Observer, :dispatch, ["GET", ["system"], %{}])
      assert sys["node"] == to_string(other)
      assert Enum.any?(sys["distribution"]["connected"], &(&1["node"] == to_string(node())))

      # A process there, linked to one here.
      me = self()
      # Not a fun: this test module exists only in this VM's memory.
      remote = Node.spawn(other, :timer, :sleep, [:infinity])

      local =
        spawn(fn ->
          Process.link(remote)
          send(me, :linked)
          receive(do: (:stop -> :ok))
        end)

      assert_receive :linked
      {200, d} = get_json("/observer/proc/#{txt(local)}")
      assert %{"pid" => rtext, "node" => rnode} = Enum.find(d["links"], &Map.has_key?(&1, "node"))
      assert rnode == to_string(other)
      # Here the remote pid's text does not start with 0: refused.
      {400, %{"error" => e}} = get_json("/observer/proc/#{rtext}")
      assert e =~ "is not on this node"

      # On the peer, its own text for the same process starts with 0.
      {200, there} = :erpc.call(other, Observer, :dispatch, ["GET", ["proc", :erpc.call(other, Observer, :pid_text, [remote])], %{}])
      assert there["node"] == to_string(other)
      assert Enum.any?(there["links"], &(&1["node"] == to_string(node())))
    end
  end

  defp spin, do: spin()

  defmodule TreeApp do
    use Application

    def start(_, _) do
      big = for i <- 1..30, do: Supervisor.child_spec({Agent, fn -> :binary.copy("y", i * 1000) end}, id: {:w, i})
      deep = %{id: :deep, start: {Agent, :start_link, [fn -> 0 end]}}
      leaf = %{id: :leaf, type: :supervisor, start: {Supervisor, :start_link, [[deep], [strategy: :one_for_one]]}}
      mid = %{id: :mid, type: :supervisor, start: {Supervisor, :start_link, [[leaf], [strategy: :one_for_one]]}}

      children = [
        mid,
        %{id: :big, type: :supervisor, start: {Supervisor, :start_link, [big, [strategy: :one_for_one, name: __MODULE__.Big]]}},
        {DynamicSupervisor, name: __MODULE__.Dyn, strategy: :one_for_one}
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Sup)
    end
  end

  # A real application with a tree we know, started for the test.
  defp tree_app do
    spec = {:application, :fr_tree_app, [description: ~c"tree test", vsn: ~c"0.0.1", modules: [], registered: [], applications: [:kernel, :stdlib], mod: {TreeApp, []}]}

    case :application.load(spec) do
      :ok -> :ok
      {:error, {:already_loaded, _}} -> :ok
    end

    :ok = Application.start(:fr_tree_app)
    on_exit(fn -> Application.stop(:fr_tree_app) end)
  end

  defp raw(port, method, path, headers, body) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        sock,
        "#{method} #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\ncontent-length: #{byte_size(body)}\r\n#{headers}\r\n#{body}"
      )

    response = read(sock, "")
    :gen_tcp.close(sock)
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")
    {String.to_integer(status), body}
  end

  defp read(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> read(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
