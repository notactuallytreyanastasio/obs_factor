defmodule ObsFactor.Deploy.WatchdogTest do
  # deploy/watchdog.sh, run for real (sh and curl) against a Bandit on a
  # free port that plays both the observer's /health and the Slack webhook.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  @script Path.expand("../../deploy/watchdog.sh", __DIR__)

  defmodule Fake do
    @behaviour Plug
    def init(opts), do: opts

    def call(%{request_path: "/health"} = conn, {health, _to}) do
      {status, body} = Agent.get(health, & &1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end

    def call(%{request_path: "/hook"} = conn, {_health, to}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(to, {:hook, Jason.decode!(body)["text"]})
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    def call(conn, _), do: Plug.Conn.send_resp(conn, 404, "no such hook")
  end

  @ok ~s({"ok":true,"snapshot_age_s":2,"sources_ok":8,"sources_total":9})
  @stale ~s({"ok":false,"reason":"snapshot_stale","snapshot_age_s":94,"sources_ok":8,"sources_total":9})

  setup do
    {:ok, health} = Agent.start_link(fn -> {200, @ok} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {Fake, {health, self()}},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    dir = Path.join(System.tmp_dir!(), "watchdog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Process.exit(server, :normal)
      File.rm_rf!(dir)
    end)

    {:ok, health: health, port: port, dir: dir}
  end

  defp run(ctx, shell \\ "sh", extra \\ []) do
    env =
      [
        {"WATCHDOG_URL", "http://127.0.0.1:#{ctx.port}/health"},
        {"WATCHDOG_WEBHOOK", "http://127.0.0.1:#{ctx.port}/hook"},
        {"WATCHDOG_FAILS", "3"},
        {"WATCHDOG_TIMEOUT", "5"},
        {"WATCHDOG_STATE", Path.join(ctx.dir, "state")},
        {"WATCHDOG_ENV", Path.join(ctx.dir, "none")},
        {"WATCHDOG_NAME", "factory"}
      ] ++ extra

    {out, status} = System.cmd(shell, [@script], env: env, stderr_to_stdout: true)
    {status, out}
  end

  defp set(ctx, status, body), do: Agent.update(ctx.health, fn _ -> {status, body} end)

  for shell <- ["sh", "dash"] do
    @tag shell: shell
    test "#{shell}: alerts once after 3 failures, once on recovery, silent otherwise", ctx do
      shell = ctx.shell
      if System.find_executable(shell) == nil, do: flunk("#{shell} not found")

      assert {0, out} = run(ctx, shell)
      assert out =~ "ok (snapshot 2 s old)"
      refute_received {:hook, _}

      set(ctx, 503, @stale)
      assert {1, out} = run(ctx, shell)
      assert out =~ "FAIL 1/3: answered 503 snapshot_stale, snapshot 94 s old"
      assert {1, _} = run(ctx, shell)
      refute_received {:hook, _}

      assert {1, out} = run(ctx, shell)
      assert out =~ "alert posted"
      assert_received {:hook, "DOWN: factory failed 3 checks in a row, the first at " <> rest}

      assert rest =~
               ~r/^\d\d:\d\d UTC: answered 503 snapshot_stale, snapshot 94 s old\. http:\/\/127\.0\.0\.1:\d+\/health$/

      assert {1, out} = run(ctx, shell)
      assert out =~ "FAIL 4 (alerted)"

      refute_received {:hook, _}

      set(ctx, 200, @ok)
      assert {0, out} = run(ctx, shell)
      assert out =~ "recovered after"
      assert_received {:hook, "RECOVERED: factory is healthy again after under a minute" <> rest}
      assert rest =~ "(snapshot 2 s old)"

      assert {0, _} = run(ctx, shell)
      refute_received {:hook, _}
      assert File.read!(Path.join(ctx.dir, "state")) =~ "fails=0\nalerted=0\nsince=0\nfirst=\n"
    end
  end

  test "a 200 that does not say ok:true is a failure (an error page, a proxy)", ctx do
    set(ctx, 200, "ok")
    assert {1, out} = run(ctx)
    assert out =~ "FAIL 1/3: answered 200"
  end

  test "nothing listening is a failure with a reason; one failure is not an alert", ctx do
    {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed} = :inet.port(sock)
    :gen_tcp.close(sock)

    assert {1, out} = run(ctx, "sh", [{"WATCHDOG_URL", "http://127.0.0.1:#{closed}/health"}])
    assert out =~ "FAIL 1/3: connection refused"
    refute_received {:hook, _}
  end

  test "a failed alert post is retried on the next run", ctx do
    set(ctx, 503, @stale)
    hook = [{"WATCHDOG_FAILS", "1"}, {"WATCHDOG_WEBHOOK", "http://127.0.0.1:#{ctx.port}/nowhere"}]
    assert {1, out} = run(ctx, "sh", hook)
    assert out =~ "alert post failed; will retry next run"
    assert File.read!(Path.join(ctx.dir, "state")) =~ "alerted=0"

    assert {1, out} = run(ctx, "sh", [{"WATCHDOG_FAILS", "1"}])
    assert out =~ "alert posted"
    assert_received {:hook, "DOWN: " <> _}
  end

  test "settings from WATCHDOG_ENV are read, not executed", ctx do
    env_file = Path.join(ctx.dir, "env")
    canary = Path.join(ctx.dir, "pwned")

    File.write!(env_file, """
    WATCHDOG_NAME="from file"
    WATCHDOG_X;touch #{canary}=1
    WATCHDOG_FAILS=1
    """)

    set(ctx, 503, @stale)

    env = [{"WATCHDOG_ENV", env_file}, {"WATCHDOG_NAME", ""}, {"WATCHDOG_FAILS", ""}]
    assert {1, _} = run(ctx, "sh", env)
    assert_received {:hook, "DOWN: from file failed 1 checks" <> _}
    refute File.exists?(canary)
  end
end
