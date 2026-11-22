defmodule ObsFactorWeb.UserSocketTest do
  use ObsFactorWeb.ChannelCase, async: true
  import Plug.Conn

  import Phoenix.ConnTest,
    only: [build_conn: 0, get: 2, get: 3, json_response: 2, init_test_session: 2]

  alias ObsFactorWeb.UserSocket

  @moduletag :capture_log

  test "a fresh token connects, and the socket is the session's" do
    assert {:ok, socket} = connect(UserSocket, %{"token" => UserSocket.token("s1")})
    assert socket.assigns.sid == "s1"
    assert UserSocket.id(socket) == "session:s1"
  end

  test "no token, a forged one and an expired one are refused" do
    assert {:error, :missing} = connect(UserSocket, %{})
    assert {:error, :invalid} = connect(UserSocket, %{"token" => "nope"})

    old =
      UserSocket.token("s1", signed_at: System.system_time(:second) - UserSocket.max_age_s() - 5)

    assert {:error, :expired} = connect(UserSocket, %{"token" => old})
  end

  describe "GET /api/socket_token" do
    test "401 without a session" do
      conn = get(build_conn(), "/api/socket_token")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "with a session: a token bound to it that the socket accepts, and the origin verdict" do
      conn =
        build_conn()
        |> init_test_session(%{authed: true, sid: "sess-a"})
        |> get("/api/socket_token", origin: "http://localhost:4000")

      body = json_response(conn, 200)
      assert {:ok, "sess-a"} = UserSocket.verify(body["token"])
      assert body["max_age_s"] == 60
      assert body["origin"] == %{"ok" => true}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "an origin the socket would refuse is named with the reason" do
      body =
        build_conn()
        |> init_test_session(%{authed: true, sid: "sess-a"})
        |> get("/api/socket_token", origin: "https://elsewhere.test")
        |> json_response(200)

      assert %{"ok" => false, "reason" => reason} = body["origin"]
      assert reason =~ "https://elsewhere.test"
      assert reason =~ "localhost"
    end

    test "a session from before sockets gets an id" do
      conn = build_conn() |> init_test_session(%{authed: true}) |> get("/api/socket_token")
      sid = get_session(conn, :sid)
      assert is_binary(sid)
      assert {:ok, ^sid} = UserSocket.verify(json_response(conn, 200)["token"])
    end
  end
end
