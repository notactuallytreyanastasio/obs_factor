defmodule ObsFactorWeb.ObserverFeedsTest do
  # Shares the application's topology, Sources, Feeds and LogRing.
  use ObsFactorWeb.ChannelCase, async: false

  # actions are logged at warning
  @moduletag :capture_log

  alias ObsFactor.Feeds
  alias ObsFactorWeb.FeedChannel

  @token "observer-actions"

  defmodule FakeApp do
    # A sub-app's /observer over real HTTP. `state` is an Agent holding
    # what each path answers ({status, body}) and every request seen.
    import Plug.Conn

    def init(state), do: state

    def call(conn, state) do
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = read_body(conn)

      seen = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_params,
        host: conn.host,
        body: body,
        auth: get_req_header(conn, "authorization"),
        by: get_req_header(conn, "x-factory-by")
      }

      Agent.update(state, &%{&1 | seen: [seen | &1.seen]})
      answers = Agent.get(state, & &1.answers)

      {status, json} =
        Map.get(
          answers,
          conn.request_path,
          {404, %{"error" => "no endpoint", "node" => "fake@app", "took_ms" => 0}}
        )

      json = if is_function(json, 1), do: json.(seen), else: json

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(json))
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:obs_factor, :observer_actions_token)
      Application.delete_env(:obs_factor, :observer_feed_intervals_ms)
      # a feed outlives its test by the linger: let it go, so the next test
      # starts its own with its own interval and no stale last payload
      for topic <- Feeds.topics(),
          String.starts_with?(topic, "observer:"),
          pid = Feeds.whereis(topic) do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          3_000 -> flunk("feed #{topic} did not stop")
        end
      end
    end)

    :ok
  end

  defp txt(pid), do: FactoryReport.Observer.pid_text(pid)
  defp actions_on, do: Application.put_env(:obs_factor, :observer_actions_token, @token)

  defp join(topic), do: subscribe_and_join(authed_socket(), FeedChannel, topic)

  # Point topology node "app" at `port`.
  defp app_at(port) do
    original = ObsFactor.topology()
    on_exit(fn -> ObsFactor.put_topology(original) end)

    nodes =
      Enum.map(original.nodes, fn
        %{id: "app"} = n -> %{n | report: "http://127.0.0.1:#{port}/report"}
        n -> n
      end)

    ObsFactor.put_topology(%{original | nodes: nodes})
  end

  defp fake_app(answers) do
    state = start_supervised!({Agent, fn -> %{answers: answers, seen: []} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {FakeApp, state},
         port: 0,
         ip: :loopback,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 100]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    app_at(port)
    state
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

  # The first payload of a fresh join: in the reply, or the first push.
  defp first_payload(reply) do
    if reply == %{} do
      assert_push "feed", payload, 3_000
      payload
    else
      reply
    end
  end

  describe "joins are checked against the topology and the members last read" do
    test "malformed topics, unknown views and bad arguments are refused with the reason" do
      for {topic, reason} <- [
            {"observer:nope:-:system", ~s(no node "nope" in the topology)},
            {"observer:caddy:-:system", "node caddy has no report URL, so no observer"},
            {"observer:observer:10.0.0.1:system",
             "the observer is one VM: member= does not apply to node observer"},
            {"observer:observer:-:flame", "no observer view \"flame\": one of system | apps"},
            {"observer:observer:-:procs:age",
             "procs:<sort> sorts by reductions, memory, message_queue_len"},
            {"observer:observer:-:proc:self", "proc:<pid> needs a pid written 0.123.0"},
            {"observer:observer:-:tree:Not-An-App", "tree:<app> needs an application name"},
            {"observer:observer",
             "observer topics are observer:<node id>:<member address or ->:<view>"},
            {"observer:a b:-:system", "observer topics are"}
          ] do
        assert {:error, %{reason: got}} = join(topic), topic
        assert String.starts_with?(got, reason), "#{topic}: #{got}"
      end

      assert Feeds.topics() |> Enum.filter(&String.starts_with?(&1, "observer:nope")) == []
    end

    test "a clustered node needs one of its current members; a single node takes none" do
      fake_app(%{})
      members(["127.0.0.1", "localhost"])

      assert {:error,
              %{reason: "app has 2 members: say which with member= (127.0.0.1, localhost)"}} =
               join("observer:app:-:system")

      assert {:error,
              %{reason: "\"10.9.9.9\" is not one of app's current members (127.0.0.1, localhost)"}} =
               join("observer:app:10.9.9.9:system")

      assert {:ok, _, _} = join("observer:app:localhost:system")

      members([])

      assert {:error, %{reason: "app is one node, not a cluster: member= does not apply"}} =
               join("observer:app:127.0.0.1:apps")
    end
  end

  describe "the observer's own VM" do
    test "tree:<app> arrives as feed payloads; a second viewer shares the feed and gets the last one at once" do
      topic = "observer:observer:-:tree:obs_factor"
      {:ok, reply, _} = join(topic)
      %{data: tree, at: at} = first_payload(reply)
      assert tree["app"] == "obs_factor"
      assert tree["tree"]["registered_name"] == "ObsFactor.Supervisor"
      assert is_binary(at)

      feed = Feeds.whereis(topic)
      {:ok, second, _} = join(topic)
      assert %{data: %{"app" => "obs_factor"}} = second
      assert Feeds.whereis(topic) == feed
    end

    test "procs:reductions samples a window; system, apps, ets, ports, proc" do
      {:ok, reply, _} = join("observer:observer:-:procs:reductions")

      assert %{
               data: %{
                 "sort" => "reductions",
                 "limit" => 50,
                 "interval_ms" => 1000,
                 "procs" => [_ | _]
               }
             } = first_payload(reply)

      store = txt(Process.whereis(ObsFactor.Store))

      for {view, key} <- [
            {"system", "otp_release"},
            {"apps", "apps"},
            {"ets", "tables"},
            {"ports", "ports"},
            {"proc:" <> store, "registered_name"}
          ] do
        {:ok, reply, _} = join("observer:observer:-:" <> view)
        assert %{data: %{^key => _}} = first_payload(reply), view
      end
    end

    test "a process that is gone is an error on the feed, with the engine's message" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      {:ok, reply, _} = join("observer:observer:-:proc:#{txt(dead)}")
      assert %{error: "observer /observer/proc/" <> rest} = first_payload(reply)
      assert rest =~ "answered 404: no process #{txt(dead)} (not alive)"
    end

    test "an action pushed on the topic is done, replied, broadcast on actions and refetches the node's feeds at once" do
      actions_on()
      Application.put_env(:obs_factor, :observer_feed_intervals_ms, %{"proc" => 60_000})
      victim = spawn(fn -> receive(do: (:never -> :ok)) end)
      topic = "observer:observer:-:proc:#{txt(victim)}"

      {:ok, reply, socket} = join(topic)
      %{data: %{"pid" => _}} = first_payload(reply)
      {:ok, %{}, _} = subscribe_and_join(authed_socket(), ObsFactorWeb.ActionsChannel, "actions")

      ref = push(socket, "action", %{"path" => "proc/#{txt(victim)}/gc", "by" => "dave (test)"})
      assert_reply ref, :ok, %{"ok" => true, "action" => "gc", "memory_after" => _}

      assert_push "action", %{
        "node" => "observer",
        "member" => nil,
        "path" => "proc/" <> _,
        "by" => "dave (test)",
        "status" => 200,
        "error" => nil,
        "result" => %{"action" => "gc"}
      }

      # the feed's interval is a minute: this one is the refetch
      assert_push "feed", %{data: %{"pid" => _}}, 2_000

      ref =
        push(socket, "action", %{
          "path" => "proc/#{txt(victim)}/exit",
          "params" => %{"reason" => "bogus"},
          "by" => "dave (test)"
        })

      assert_reply ref, :error, %{status: 400, error: "reason must be one of" <> _}
      assert_push "action", %{"status" => 400, "params" => %{"reason" => "bogus"}}

      ref = push(socket, "action", %{"path" => "proc/#{txt(victim)}/kill"})
      assert_reply ref, :error, %{status: 400, error: "say who is acting" <> _}
      assert Process.alive?(victim)

      ref = push(socket, "action", %{"nothing" => true})
      assert_reply ref, :error, %{status: 400, error: "action needs {path, params, by}" <> _}

      ref = push(socket, "whatever", %{})

      assert_reply ref, :error, %{
        error: "\"whatever\" is not an event of observer:observer:-:proc:" <> _
      }
    end

    test "without OBSERVER_ACTIONS_TOKEN an action pushed is refused, and still broadcast" do
      victim = spawn(fn -> receive(do: (:never -> :ok)) end)
      {:ok, _, socket} = join("observer:observer:-:system")
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, "actions")
      ref = push(socket, "action", %{"path" => "proc/#{txt(victim)}/kill", "by" => "eve"})

      assert_reply ref, :error, %{
        status: 403,
        error: "actions are off: OBSERVER_ACTIONS_TOKEN is not set on the observer"
      }

      assert_receive {:action, %{"status" => 403, "by" => "eve"}}
      assert Process.alive?(victim)
    end

    test "a payload the channel refuses itself is still recorded on actions, and a blank by is nobody" do
      {:ok, _, socket} = join("observer:observer:-:system")
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, "actions")

      ref = push(socket, "action", %{"params" => %{}, "by" => "rc"})
      assert_reply ref, :error, %{status: 400, error: "action needs {path, params, by}" <> _}
      assert_receive {:action, %{"status" => 400, "by" => "rc", "path" => "", "error" => "action needs" <> _}}

      ref = push(socket, "action", %{"path" => "proc/0.50.0/gc", "params" => [1], "by" => "rc"})
      assert_reply ref, :error, %{status: 400, error: "action params must be an object, got [1]"}
      assert_receive {:action, %{"status" => 400, "path" => "proc/0.50.0/gc", "params" => %{}}}

      for blank <- ["\u0007", "   ", " \u0007 "] do
        ref = push(socket, "action", %{"path" => "proc/0.50.0/gc", "params" => %{}, "by" => blank})
        assert_reply ref, :error, %{status: 400, error: "say who is acting" <> _}
        assert_receive {:action, %{"status" => 400, "by" => nil}}
      end
    end
  end

  describe "a sub-app over HTTP" do
    test "the feed fetches the app's /observer on its interval, with the report token, and broadcasts it" do
      Application.put_env(:obs_factor, :observer_feed_intervals_ms, %{"system" => 100})
      sources = Application.get_env(:obs_factor, :sources)

      Application.put_env(
        :obs_factor,
        :sources,
        Keyword.put(sources, :report_token, "read-token")
      )

      on_exit(fn -> Application.put_env(:obs_factor, :sources, sources) end)

      counter = :counters.new(1, [])

      app =
        fake_app(%{
          "/observer/system" =>
            {200,
             fn _ ->
               :counters.add(counter, 1, 1)

               %{
                 "otp_release" => "28",
                 "n" => :counters.get(counter, 1),
                 "node" => "fake@app",
                 "took_ms" => 0.1
               }
             end}
        })

      {:ok, reply, _} = join("observer:app:-:system")
      %{data: %{"otp_release" => "28", "node" => "fake@app"}} = first_payload(reply)
      assert_push "feed", %{data: %{"n" => _}}, 1_000
      assert_push "feed", %{data: %{"n" => _}}, 1_000

      seen = Agent.get(app, & &1.seen)

      assert Enum.all?(
               seen,
               &(&1.method == "GET" and &1.path == "/observer/system" and
                   &1.auth == ["Bearer read-token"])
             )

      assert length(seen) >= 3
    end

    test "procs:memory asks for 50 by memory; a member's feed goes to that member" do
      app =
        fake_app(%{
          "/observer/procs" =>
            {200,
             fn s -> %{"procs" => [], "host" => s.host, "node" => "fake@app", "took_ms" => 0} end}
        })

      members(["127.0.0.1", "localhost"])

      {:ok, reply, _} = join("observer:app:localhost:procs:memory")
      assert %{data: %{"host" => "localhost"}} = first_payload(reply)
      assert [%{query: %{"sort" => "memory", "limit" => "50"}} | _] = Agent.get(app, & &1.seen)
    end

    test "the app's errors, a non-engine answer and an app that is down are feed errors that say so" do
      fake_app(%{
        "/observer/tree/nope" =>
          {404,
           %{"error" => "no started application \"nope\"", "node" => "fake@app", "took_ms" => 0}},
        "/observer/system" => {200, %{"hello" => "not an engine"}}
      })

      {:ok, reply, _} = join("observer:app:-:tree:nope")

      assert %{error: ~s(app /observer/tree/nope answered 404: no started application "nope")} =
               first_payload(reply)

      {:ok, reply, _} = join("observer:app:-:system")
      assert %{error: "app answered 200 without \"node\"" <> _} = first_payload(reply)

      {:ok, sock} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)
      app_at(port)
      {:ok, reply, _} = join("observer:app:-:ets")
      assert %{error: "app /observer/ets answered 502: 127.0.0.1:" <> rest} = first_payload(reply)
      assert rest =~ "connection refused"
    end

    test "an action is forwarded with the actions token and who, broadcast, and the app's feeds refetched" do
      actions_on()
      Application.put_env(:obs_factor, :observer_feed_intervals_ms, %{"tree" => 60_000})

      app =
        fake_app(%{
          "/observer/tree/blog" =>
            {200, %{"app" => "blog", "tree" => %{}, "node" => "fake@app", "took_ms" => 0}},
          "/observer/tree/blog/restart" =>
            {200,
             %{
               "ok" => true,
               "action" => "restart",
               "old_pid" => "0.300.0",
               "new_pid" => "0.301.0",
               "node" => "fake@app",
               "took_ms" => 1
             }}
        })

      {:ok, reply, socket} = join("observer:app:-:tree:blog")
      %{data: %{"app" => "blog"}} = first_payload(reply)
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, "actions")

      ref =
        push(socket, "action", %{
          "path" => "tree/blog/restart",
          "params" => %{"supervisor" => "0.250.0", "child_id" => "Blog.Worker", "by" => "dropped"},
          "by" => "carol"
        })

      assert_reply ref, :ok, %{"ok" => true, "new_pid" => "0.301.0"}

      assert_receive {:action,
                      %{
                        "node" => "app",
                        "path" => "tree/blog/restart",
                        "params" => %{"supervisor" => "0.250.0", "child_id" => "Blog.Worker"},
                        "by" => "carol",
                        "status" => 200
                      }}

      assert_push "feed", %{data: %{"app" => "blog"}}, 2_000

      [post] = app |> Agent.get(& &1.seen) |> Enum.filter(&(&1.method == "POST"))
      assert post.path == "/observer/tree/blog/restart"
      assert post.auth == ["Bearer #{@token}"]
      assert post.by == ["carol"]
      assert Jason.decode!(post.body) == %{"supervisor" => "0.250.0", "child_id" => "Blog.Worker"}
    end
  end
end
