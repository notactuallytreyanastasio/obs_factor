defmodule ObsFactorWeb.IdentityTest do
  @moduledoc """
  Sign in with GitHub against a fake GitHub (Req's `plug:` option, through
  `Req.Test`), the allow list and the roles it gives, the password as the
  break glass, and the roles enforced on the HTTP side: `GET /api/me`,
  `POST /api/nodes/:id/observer/*`.
  """
  use ObsFactorWeb.ConnCase, async: false

  # sign-ins, refusals and actions are logged
  @moduletag :capture_log

  require Phoenix.ChannelTest

  alias ObsFactorWeb.{Identity, UserSocket}

  @password "correct horse battery staple"
  @actions_token "observer-actions"

  setup do
    Application.put_env(:obs_factor, :identity,
      github_client_id: "cid",
      github_client_secret: "csecret",
      allowed_logins: ["Viewer-Vera"],
      operators: ["opal"],
      github_req_options: [plug: {Req.Test, ObsFactor.GitHubOAuth}]
    )

    on_exit(fn ->
      Application.delete_env(:obs_factor, :identity)
      Application.delete_env(:obs_factor, :observer_actions_token)
    end)

    :ok
  end

  # GitHub, as far as the web flow goes: the code "code-<login>" is good for
  # that login, anything else is answered the way GitHub answers a bad code
  # (200 with an error). Every request is sent to the test process.
  defp fake_github do
    test = self()

    Req.Test.stub(ObsFactor.GitHubOAuth, fn conn ->
      send(test, {:github, conn.method, conn.host, conn.request_path, conn})

      case {conn.method, conn.host, conn.request_path} do
        {"POST", "github.com", "/login/oauth/access_token"} ->
          {:ok, body, _} = Plug.Conn.read_body(conn)
          form = URI.decode_query(body)

          cond do
            form["client_id"] != "cid" or form["client_secret"] != "csecret" ->
              Req.Test.json(conn, %{"error" => "incorrect_client_credentials"})

            String.starts_with?(form["code"], "code-") ->
              Req.Test.json(conn, %{
                "access_token" => "gho_" <> String.trim_leading(form["code"], "code-"),
                "token_type" => "bearer",
                "scope" => ""
              })

            true ->
              Req.Test.json(conn, %{
                "error" => "bad_verification_code",
                "error_description" => "The code passed is incorrect or expired."
              })
          end

        {"GET", "api.github.com", "/user"} ->
          case Plug.Conn.get_req_header(conn, "authorization") do
            ["Bearer gho_" <> login] ->
              Req.Test.json(conn, %{"login" => login, "id" => 1, "name" => nil})

            _ ->
              conn
              |> Plug.Conn.put_status(401)
              |> Req.Test.json(%{"message" => "Bad credentials"})
          end
      end
    end)
  end

  # GET /auth/github, then GitHub's redirect back with `code`
  defp github_sign_in(code) do
    fake_github()
    conn = get(build_conn(), "/auth/github")
    to = redirected_to(conn, 302)
    q = URI.decode_query(URI.parse(to).query)
    conn |> recycle() |> get("/auth/github/callback", %{"code" => code, "state" => q["state"]})
  end

  defp why(conn) do
    "/login?" <> q = redirected_to(conn, 302)
    URI.decode_query(q)
  end

  describe "Sign in with GitHub" do
    test "the button is on /login, and /auth/github sends the browser to GitHub with a state" do
      html = build_conn() |> get("/login") |> html_response(200)
      assert html =~ ~s(href="/auth/github")
      assert html =~ ~s(action="/login")

      conn = get(build_conn(), "/auth/github")
      uri = URI.parse(redirected_to(conn, 302))
      assert {uri.host, uri.path} == {"github.com", "/login/oauth/authorize"}
      q = URI.decode_query(uri.query)
      assert q["client_id"] == "cid"
      assert q["redirect_uri"] == ObsFactorWeb.Endpoint.url() <> "/auth/github/callback"
      assert byte_size(q["state"]) == 32
      assert get_session(conn, :oauth_state) == q["state"]
    end

    test "an operator signs in: the session holds the login and role, /api/me says so" do
      conn = github_sign_in("code-opal")
      assert redirected_to(conn, 302) == "/"

      assert get_session(conn, :identity) == %{
               "login" => "opal",
               "role" => "operator",
               "via" => "github"
             }

      assert get_session(conn, :oauth_state) == nil

      # the code went to GitHub with the secret, and the token to /user
      assert_received {:github, "POST", "github.com", "/login/oauth/access_token", _}
      assert_received {:github, "GET", "api.github.com", "/user", _}

      me = conn |> recycle() |> get("/api/me") |> json_response(200)

      assert %{"login" => "opal", "role" => "operator", "via" => "github", "operator" => true} =
               me
    end

    test "an allowed login that is not an operator is a viewer; logins compare without case" do
      conn = github_sign_in("code-viewer-vera")
      assert redirected_to(conn, 302) == "/"

      assert %{"login" => "viewer-vera", "role" => "viewer", "operator" => false} =
               conn |> recycle() |> get("/api/me") |> json_response(200)
    end

    test "a login on neither list is refused and gets no session" do
      conn = github_sign_in("code-mallory")

      assert %{
               "error" => "github",
               "why" => "mallory is not allowed on this observer (GITHUB_ALLOWED_LOGINS)"
             } = why(conn)

      assert get_session(conn, :authed) == nil
      assert conn |> recycle() |> get("/api/me") |> json_response(401)
    end

    test "a bad code, a forged state, and no state at all are refused" do
      fake_github()
      conn = get(build_conn(), "/auth/github")

      conn =
        conn
        |> recycle()
        |> get("/auth/github/callback", %{"code" => "code-opal", "state" => "not-the-one"})

      assert why(conn)["why"] =~ "does not match"
      assert get_session(conn, :authed) == nil
      # the state was spent: GitHub was never asked
      refute_received {:github, _, _, _, _}

      conn = get(build_conn(), "/auth/github/callback", %{"code" => "code-opal", "state" => "x"})
      assert why(conn)["why"] =~ "no sign-in was started"

      assert why(github_sign_in("nonsense"))["why"] ==
               "GitHub refused the code: bad_verification_code (The code passed is incorrect or expired.)"
    end

    test "taken off the list, a signed-in login is signed out at its next request" do
      conn = github_sign_in("code-viewer-vera") |> recycle()
      assert conn |> get("/api/me") |> json_response(200)

      Application.put_env(
        :obs_factor,
        :identity,
        Keyword.put(Application.get_env(:obs_factor, :identity), :allowed_logins, [])
      )

      assert conn |> get("/api/me") |> json_response(401)
    end

    test "made an operator, the next request has the role" do
      conn = github_sign_in("code-viewer-vera") |> recycle()

      Application.put_env(
        :obs_factor,
        :identity,
        Keyword.put(Application.get_env(:obs_factor, :identity), :operators, [
          "opal",
          "VIEWER-VERA"
        ])
      )

      assert %{"role" => "operator"} = conn |> get("/api/me") |> json_response(200)
    end

    test "not configured: no button, and /auth/github says why" do
      Application.put_env(:obs_factor, :identity, [])
      refute build_conn() |> get("/login") |> html_response(200) =~ "/auth/github"
      assert why(get(build_conn(), "/auth/github"))["why"] =~ "not configured"
    end
  end

  describe "the password, the break glass" do
    test "still signs in, as an operator with no login: the page signs with the typed name" do
      conn = post(build_conn(), "/login", %{"password" => @password})
      assert redirected_to(conn, 302) == "/"

      assert %{"login" => nil, "role" => "operator", "via" => "password"} =
               conn |> recycle() |> get("/api/me") |> json_response(200)

      assert redirected_to(post(build_conn(), "/login", %{"password" => "nope"}), 302) ==
               "/login?error=1"
    end

    test "its role can be viewer" do
      Application.put_env(:obs_factor, :identity, password_role: "viewer")
      conn = post(build_conn(), "/login", %{"password" => @password}) |> recycle()

      assert %{"role" => "viewer", "via" => "password"} =
               conn |> get("/api/me") |> json_response(200)
    end

    test "switched off: no form, the right password is refused, and its sessions end" do
      conn = post(build_conn(), "/login", %{"password" => @password}) |> recycle()
      # a session from before identities: authed and nothing else
      legacy = build_conn() |> init_test_session(%{authed: true})
      assert legacy |> get("/api/me") |> json_response(200) |> Map.get("via") == "password"

      Application.put_env(
        :obs_factor,
        :identity,
        Keyword.put(Application.get_env(:obs_factor, :identity), :password_login, false)
      )

      html = build_conn() |> get("/login") |> html_response(200)
      refute html =~ ~s(action="/login")
      assert html =~ "/auth/github"

      assert redirected_to(post(build_conn(), "/login", %{"password" => @password}), 302) ==
               "/login?error=off"

      assert conn |> get("/api/me") |> json_response(401)
      assert legacy |> get("/api/me") |> json_response(401)
    end
  end

  describe "the socket token" do
    test "carries the identity in its claims; a bare sid has none" do
      conn = github_sign_in("code-viewer-vera") |> recycle()
      token = conn |> get("/api/socket_token") |> json_response(200) |> Map.get("token")

      assert {:ok, %{identity: %{"login" => "viewer-vera", "role" => "viewer"}}} =
               UserSocket.claims(token)

      assert {:ok, sid} = UserSocket.verify(token)
      assert is_binary(sid)

      assert {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => token})
      assert socket.assigns.identity["role"] == "viewer"

      assert {:ok, socket} =
               Phoenix.ChannelTest.connect(UserSocket, %{"token" => UserSocket.token("bare")})

      assert socket.assigns.identity == nil
    end
  end

  describe "POST /api/nodes/:id/observer/*: operators only" do
    setup do
      Application.put_env(:obs_factor, :observer_actions_token, @actions_token)
      :ok
    end

    defp act(conn, path),
      do:
        conn
        |> put_req_header("x-factory-by", "typed name")
        |> put_req_header("content-type", "application/json")
        |> post(path, "{}")

    test "a viewer is refused with 403, the process lives, and the refusal is an action everyone sees" do
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, ObsFactor.ObserverProxy.actions_topic())
      victim = spawn(fn -> receive(do: (:never -> :ok)) end)
      conn = github_sign_in("code-viewer-vera") |> recycle()

      body =
        conn
        |> act(
          "/api/nodes/observer/observer/proc/#{FactoryReport.Observer.pid_text(victim)}/kill"
        )
        |> json_response(403)

      assert body["error"] ==
               "only an operator may act on a process (observer action); github:viewer-vera is a viewer"

      assert Process.alive?(victim)
      # signed with the login, not the header
      assert_receive {:action, %{"by" => "viewer-vera", "status" => 403}}
    end

    test "an operator acts, signed with the login whatever the header says" do
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, ObsFactor.ObserverProxy.actions_topic())
      victim = spawn(fn -> receive(do: (:never -> :ok)) end)
      conn = github_sign_in("code-opal") |> recycle()

      assert %{"ok" => true} =
               conn
               |> act(
                 "/api/nodes/observer/observer/proc/#{FactoryReport.Observer.pid_text(victim)}/gc"
               )
               |> json_response(200)

      assert_receive {:action, %{"by" => "opal", "status" => 200}}
    end
  end

  test "authorize/3 and by/2" do
    viewer = %{"login" => "v", "role" => "viewer", "via" => "github"}
    assert :ok = Identity.authorize(viewer, "save_writeup")

    assert {:error, "only an operator may make a script token" <> _} =
             Identity.authorize(viewer, "create_token")

    assert {:error, _} = Identity.authorize(nil, "observer_action")
    assert Identity.by(viewer, "someone else") == "v"
    assert Identity.by(Identity.password_identity(), "  dave (floor) ") == "dave (floor)"
    assert Identity.by(Identity.password_identity(), nil) == nil
  end
end
