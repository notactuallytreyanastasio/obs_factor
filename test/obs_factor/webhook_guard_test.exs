defmodule ObsFactor.WebhookGuardTest do
  @moduledoc """
  Where the observer may POST (ObsFactor.WebhookGuard), with a real socket
  for what its own POST does, and the writeup schedules that go through it
  (against a real Postgres, as ObsFactor.TokensSchedulesTest).
  """
  use ExUnit.Case, async: false

  alias ObsFactor.{Tape, WebhookGuard}
  alias ObsFactor.Writeup.Schedules

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS writeup_schedules", [])
    on_exit(fn -> Application.delete_env(:obs_factor, :alert_allow_private_hosts) end)
    :ok
  end

  test "private, loopback, link-local and mapped addresses are refused; public ones pass" do
    for u <- ~w(http://127.0.0.1:4000/x http://10.0.0.5/ https://172.20.0.2/hook http://192.168.1.1/ http://169.254.169.254/latest/meta-data
                http://100.64.0.1/ http://0.0.0.0/ http://[::1]/ http://[::ffff:127.0.0.1]/ http://[fe80::1]/ http://[fd00::5]/
                http://localhost:4000/ http://api.localhost/ http://LOCALHOST./) do
      assert {:error, why} = WebhookGuard.check(u), u
      assert why =~ "refused", u
    end

    assert {:ok, "https://93.184.216.34/x"} = WebhookGuard.check(" https://93.184.216.34/x ")
    assert {:ok, _} = WebhookGuard.check("https://[2606:4700::1111]/x")
    assert {:error, "a webhook is an http(s) URL"} = WebhookGuard.check("file:///etc/passwd")
    assert {:error, "a webhook is an http(s) URL"} = WebhookGuard.check("gopher://127.0.0.1/")
  end

  test "a name is judged by what it resolves to; unresolvable passes a save, not a send" do
    to_meta = fn _ -> {:ok, [{8, 8, 8, 8}, {169, 254, 169, 254}]} end
    assert {:error, "hooks.evil.test (169.254.169.254) is a private" <> _} = WebhookGuard.check("https://hooks.evil.test/x", resolve: to_meta)
    assert {:ok, _} = WebhookGuard.check("https://hooks.ok.test/x", resolve: fn _ -> {:ok, [{8, 8, 8, 8}]} end)
    nx = fn _ -> {:error, :nxdomain} end
    assert {:ok, _} = WebhookGuard.check("https://hooks.example/x", resolve: nx)
    assert {:error, "hooks.example does not resolve"} = WebhookGuard.check("https://hooks.example/x", resolve: nx, send: true)
  end

  test "ALERT_ALLOW_PRIVATE_HOSTS lifts it" do
    Application.put_env(:obs_factor, :alert_allow_private_hosts, true)
    assert {:ok, _} = WebhookGuard.check("http://127.0.0.1:4000/x")
  end

  test "post sends JSON, refuses a private host before connecting, and does not follow a redirect" do
    assert {:error, "127.0.0.1 is a private" <> _} = WebhookGuard.post("http://127.0.0.1:1/", %{text: "x"})

    ok = fake_server("200 OK")
    assert :ok = WebhookGuard.post("http://127.0.0.1:#{ok}/hook", %{text: "hi"}, allow_private: true)
    assert_receive {:http, req}
    assert req =~ "POST /hook HTTP/1.1"
    assert req =~ ~s({"text":"hi"})

    # a public-looking hook that sends the observer on to the metadata service
    redirect = fake_server("302 Found", "location: http://169.254.169.254/latest/meta-data\r\n")
    assert {:error, "answered 302 (a redirect, not followed)"} = WebhookGuard.post("http://127.0.0.1:#{redirect}/", %{text: "x"}, allow_private: true)
    assert_receive {:http, _}
    refute_receive {:http, _}, 200
  end

  test "writeup schedules go through it too" do
    assert {:error, "169.254.169.254 is a private" <> _} =
             Schedules.save(%{"name" => "x", "every" => "daily", "hour" => 9, "webhook" => "http://169.254.169.254/latest/meta-data"})

    assert {:error, "127.0.0.1 is a private" <> _} = Schedules.post("http://127.0.0.1:4000/api/objectives", %{text: "x"})
  end

  # ---- a webhook on a real socket ------------------------------------------

  defp fake_server(status, headers \\ "") do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    me = self()
    spawn_link(fn -> serve(l, me, status, headers) end)
    port
  end

  defp serve(l, me, status, headers) do
    case :gen_tcp.accept(l, 5_000) do
      {:ok, s} ->
        send(me, {:http, read_req(s, "")})
        :gen_tcp.send(s, "HTTP/1.1 #{status}\r\n#{headers}content-length: 2\r\nconnection: close\r\n\r\nok")
        :gen_tcp.close(s)
        serve(l, me, status, headers)

      _ ->
        :ok
    end
  end

  defp read_req(s, acc) do
    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, n] <- Regex.run(~r/content-length: (\d+)/i, head),
         true <- byte_size(body) >= String.to_integer(n) do
      acc
    else
      _ ->
        case :gen_tcp.recv(s, 0, 2_000) do
          {:ok, more} -> read_req(s, acc <> more)
          _ -> acc
        end
    end
  end
end
