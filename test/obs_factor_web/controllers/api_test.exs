defmodule ObsFactorWeb.ApiTest do
  # Shares the application's Store, History and pages_dir.
  use ObsFactorWeb.ConnCase, async: false

  alias ObsFactor.{Fixtures, History, Snapshot, Store}

  @password "correct horse battery staple"

  setup do
    dir = Path.join(System.tmp_dir!(), "obs_factor_pages_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:obs_factor, :pages_dir, dir)

    on_exit(fn ->
      Application.delete_env(:obs_factor, :pages_dir)
      File.rm_rf!(dir)
    end)

    {:ok, pages: dir}
  end

  defp login(conn, password \\ @password), do: post(conn, "/login", %{"password" => password})

  defp authed(conn) do
    conn = login(conn)
    conn |> recycle()
  end

  describe "health" do
    test "is public and says ok", %{conn: conn} do
      assert conn |> get("/health") |> text_response(200) == "ok"
    end
  end

  describe "login flow" do
    test "a wrong password redirects to /login?error=1", %{conn: conn} do
      conn = login(conn, "wrong")
      assert redirected_to(conn) == "/login?error=1"
      assert get_session(conn, :authed) == nil
    end

    test "a missing password field is a failure, not a crash", %{conn: conn} do
      assert conn |> post("/login", %{}) |> redirected_to() == "/login?error=1"
    end

    test "the right password sets the session and redirects to /", %{conn: conn} do
      conn = login(conn)
      assert redirected_to(conn) == "/"
      assert get_session(conn, :authed) == true
    end

    test "logout clears it", %{conn: conn} do
      conn = conn |> authed() |> post("/logout")
      assert redirected_to(conn) == "/login"
      conn = conn |> recycle() |> get("/api/snapshot")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "password comparison is exact", _ do
      assert ObsFactorWeb.AuthController.valid_password?(@password)
      refute ObsFactorWeb.AuthController.valid_password?(@password <> " ")
      refute ObsFactorWeb.AuthController.valid_password?("")
      refute ObsFactorWeb.AuthController.valid_password?(nil)
    end
  end

  describe "the gate" do
    test "/ redirects to /login without a session", %{conn: conn} do
      assert conn |> get("/") |> redirected_to() == "/login"
    end

    test "/api/* answers 401 JSON without a session", %{conn: conn} do
      for path <- ["/api/snapshot", "/api/history?node=db", "/api/stream"] do
        assert build_conn() |> get(path) |> json_response(401) == %{"error" => "unauthorized"}
      end

      _ = conn
    end
  end

  describe "pages" do
    test "asset URLs carry a content version, and modules import through it", %{conn: conn, pages: dir} do
      File.mkdir_p!(Path.join(dir, "assets/js"))
      File.write!(Path.join(dir, "assets/app.css"), "p {}")
      File.write!(Path.join(dir, "assets/js/main.js"), ~s(import "./beam.js";))
      File.write!(Path.join(dir, "assets/js/beam.js"), "1")

      File.write!(Path.join(dir, "index.html"), """
      <link rel="stylesheet" href="/assets/app.css">
      <script type="module" src="/assets/js/main.js"></script>
      """)

      page = fn -> conn |> authed() |> get("/") |> html_response(200) end
      html = page.()
      [_, v] = Regex.run(~r{href="/assets/app.css\?v=([\w-]+)"}, html)
      assert html =~ ~s(src="/assets/js/main.js?v=#{v}")
      [_, map] = Regex.run(~r{<script type="importmap">(.*?)</script>\s*<script type="module"}s, html)

      assert Jason.decode!(map)["imports"] == %{
               "/assets/js/beam.js" => "/assets/js/beam.js?v=#{v}",
               "/assets/js/main.js" => "/assets/js/main.js?v=#{v}"
             }

      # A changed module is a new version for every URL, not only its own: an
      # unchanged main.js still has to be refetched to reach the new beam.js.
      File.write!(Path.join(dir, "assets/js/beam.js"), "2")
      refute page.() =~ "?v=#{v}"
    end

    test "/ serves priv/static/index.html when it exists", %{conn: conn, pages: dir} do
      File.write!(Path.join(dir, "index.html"), "<p>factory</p>")
      assert conn |> authed() |> get("/") |> html_response(200) == "<p>factory</p>"
    end

    test "a missing page is a 500 that names the file", %{conn: conn} do
      conn = conn |> authed() |> get("/")
      assert conn.status == 500
      assert conn.resp_body =~ "priv/static/index.html is missing"

      conn = build_conn() |> get("/login")
      assert conn.status == 500
      assert conn.resp_body =~ "priv/static/login.html is missing"
    end

    test "/login is public", %{conn: conn, pages: dir} do
      File.write!(Path.join(dir, "login.html"), "<form></form>")
      assert conn |> get("/login") |> html_response(200) == "<form></form>"
    end
  end

  describe "snapshot and history" do
    test "503 before the first tick, the stored JSON after", %{conn: conn} do
      Store.clear_snapshot()
      conn = authed(conn)
      assert conn |> get("/api/snapshot") |> json_response(503) == %{"error" => "no snapshot yet"}

      {snap, _} =
        Snapshot.build(
          Fixtures.topology(),
          Fixtures.sources(),
          Snapshot.empty_memory(),
          Fixtures.now()
        )

      Store.put_snapshot({:ok, Jason.encode!(snap)})
      body = conn |> get("/api/snapshot") |> json_response(200)
      assert body["at"] == "2026-11-18T22:34:52Z"
      assert Enum.any?(body["nodes"], &(&1["id"] == "temper-link"))

      Store.put_snapshot({:error, "boom"})

      assert conn |> get("/api/snapshot") |> json_response(500) == %{
               "error" => "snapshot build failed: boom"
             }
    end

    test "history: series for a known node, 404 for an unknown one, 400 for a bad res", %{
      conn: conn
    } do
      History.record(1_795_041_305_000, %{"probe-node" => %{cpu_cores: 0.007}})
      _ = :sys.get_state(History)
      conn = authed(conn)

      assert %{"node" => "probe-node", "res" => "5s", "series" => [series]} =
               conn |> get("/api/history?node=probe-node&res=5s") |> json_response(200)

      assert series["key"] == "cpu_cores"
      assert [1_795_041_305_000, 0.007] in series["points"]

      assert conn |> get("/api/history?node=nope") |> json_response(404) == %{
               "error" => "unknown node nope"
             }

      assert conn |> get("/api/history?node=probe-node&res=1h") |> json_response(400)
    end
  end
end
