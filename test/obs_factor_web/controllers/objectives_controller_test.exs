defmodule ObsFactorWeb.ObjectivesControllerTest do
  @moduledoc """
  /api/objectives over HTTP. Without a store: 503 with the reason. With one
  (ObsFactor.Objectives under its default name, against the same Postgres
  as test/obs_factor/objectives_test.exs): pin, act, list.
  """
  use ObsFactorWeb.ConnCase, async: false

  alias ObsFactor.Objectives

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  defp authed(conn) do
    conn |> post("/login", %{"password" => Application.fetch_env!(:obs_factor, :password)}) |> recycle()
  end

  defp api(conn, method, path, body \\ nil) do
    conn = authed(conn) |> put_req_header("content-type", "application/json")
    if body, do: dispatch(conn, @endpoint, method, path, Jason.encode!(body)), else: dispatch(conn, @endpoint, method, path)
  end

  describe "with no objectives store" do
    test "every endpoint is 503 and says why", %{conn: conn} do
      refute Objectives.enabled?()
      no = %{"error" => "no objectives store: OBJECTIVES_PG_URL is not set"}
      assert conn |> api(:get, "/api/objectives") |> json_response(503) == no
      assert build_conn() |> api(:post, "/api/objectives", %{"node" => "blog", "title" => "x"}) |> json_response(503) == no
      assert build_conn() |> api(:post, "/api/objectives/1", %{"action" => "look"}) |> json_response(503) == no
    end

    test "logged out is 401, not 503", %{conn: conn} do
      assert conn |> get("/api/objectives") |> json_response(401) == %{"error" => "unauthorized"}
    end
  end

  describe "with a store" do
    setup do
      case ensure_database(@url) do
        :ok ->
          db = :"objectives_ctl_db_#{System.unique_integer([:positive])}"
          start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 1, statement_timeout: "5000")}, id: db))
          Postgrex.query!(db, "DROP TABLE IF EXISTS objective_events, objectives", [])
          start_supervised!({Objectives, db: db})
          wait_ready()
          :ok

        {:error, why} ->
          # fail, not skip: this file's other half proved the endpoint exists
          flunk("no Postgres for the objectives controller test at #{@url}: #{why}")
      end
    end

    test "pin, look, cross off with a note, reopen, and the list says each", %{conn: conn} do
      pin = conn |> api(:post, "/api/objectives", %{"node" => "blog", "title" => "blog feels slow", "note" => "p99?", "by" => "bg"}) |> json_response(201)
      assert %{"id" => id, "source" => "pin", "state" => "open", "node" => "blog", "severity" => "warn", "note" => "p99?"} = pin

      assert %{"objectives" => [listed]} = build_conn() |> api(:get, "/api/objectives") |> json_response(200)
      assert listed["id"] == id
      assert [%{"kind" => "pinned", "by" => "bg", "note" => "p99?"}] = listed["events"]

      look = build_conn() |> api(:post, "/api/objectives/#{id}", %{"action" => "look", "by" => "ana"}) |> json_response(200)
      assert look["state"] == "looking" and look["looking_by"] == "ana"

      done = build_conn() |> api(:post, "/api/objectives/#{id}", %{"action" => "done", "by" => "ana", "note" => "a cold cache"}) |> json_response(200)
      assert done["state"] == "done" and done["done_by"] == "ana" and done["note"] == "a cold cache"

      assert %{"objectives" => [d]} = build_conn() |> api(:get, "/api/objectives") |> json_response(200)
      assert d["state"] == "done"
      assert Enum.map(d["events"], & &1["kind"]) == ["pinned", "looking", "crossed off"]

      again = build_conn() |> api(:post, "/api/objectives/#{id}", %{"action" => "reopen", "by" => "bg"}) |> json_response(200)
      assert again["state"] == "open" and again["done_at"] == nil
    end

    test "a rule's objective from a tick is listed with what it saw", %{conn: conn} do
      Objectives.observe([%{node: "db", severity: "alert", text: "Postgres connections 97 of 100"}], %{"db" => %{label: "Postgres", status: "blocked"}})
      assert %{"objectives" => [o]} = conn |> api(:get, "/api/objectives") |> json_response(200)
      assert %{"source" => "rule", "severity" => "alert", "node" => "db", "state" => "open", "evidence" => %{"label" => "Postgres"}} = o
    end

    test "what cannot be done is 409, an unknown one 404, a bad action or id 400", %{conn: conn} do
      %{"id" => id} = conn |> api(:post, "/api/objectives", %{"node" => "blog", "title" => "x", "by" => "bg"}) |> json_response(201)
      assert %{"error" => "cannot reopen an objective that is open"} = build_conn() |> api(:post, "/api/objectives/#{id}", %{"action" => "reopen"}) |> json_response(409)
      assert %{"error" => "no such objective"} = build_conn() |> api(:post, "/api/objectives/999999", %{"action" => "look"}) |> json_response(404)
      assert %{"error" => "action must be" <> _} = build_conn() |> api(:post, "/api/objectives/#{id}", %{"action" => "nuke"}) |> json_response(400)
      assert %{"error" => "not an objective id" <> _} = build_conn() |> api(:post, "/api/objectives/abc", %{"action" => "look"}) |> json_response(400)
    end
  end

  defp wait_ready(n \\ 40) do
    case Objectives.list() do
      {:ok, _} -> :ok
      _ when n > 0 -> Process.sleep(50) && wait_ready(n - 1)
      other -> flunk("objectives store did not start: #{inspect(other)}")
    end
  end

  defp ensure_database(url) do
    uri = URI.parse(url)
    db = String.trim_leading(uri.path, "/")
    admin = %{uri | path: "/postgres"} |> URI.to_string()

    case Postgrex.start_link(ObsFactor.Postgres.opts(admin, name: nil, pool_size: 1, statement_timeout: "5000") |> Keyword.delete(:name) |> Keyword.put(:backoff_type, :stop)) do
      {:ok, pid} ->
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

      {:error, e} ->
        {:error, inspect(e)}
    end
  end
end
