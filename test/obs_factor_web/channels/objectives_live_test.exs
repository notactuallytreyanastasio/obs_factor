defmodule ObsFactorWeb.ObjectivesLiveTest do
  @moduledoc """
  What the Missions panel (missions.js) relies on, with a real store against
  the same Postgres as test/obs_factor/objectives_test.exs: two viewers on
  the `objectives` channel; whatever one does over the channel, or anyone
  does over HTTP, reaches the other as an `objective` push with the whole
  row and its events, which is all the panel uses to change its list.
  """
  use ObsFactorWeb.ChannelCase, async: false
  import Plug.Conn, only: [put_req_header: 3]
  import Phoenix.ConnTest, only: [build_conn: 0, recycle: 1, dispatch: 5, post: 3, json_response: 2]

  alias ObsFactor.Objectives
  alias Phoenix.Socket.Message

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  setup do
    case ensure_database(@url) do
      :ok ->
        db = :"objectives_live_db_#{System.unique_integer([:positive])}"
        start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 1, statement_timeout: "5000")}, id: db))
        Postgrex.query!(db, "DROP TABLE IF EXISTS objective_events, objectives", [])
        start_supervised!({Objectives, db: db})
        wait_ready()
        :ok

      {:error, why} ->
        flunk("no Postgres for the objectives live test at #{@url}: #{why}")
    end
  end

  # Viewer B in its own process, so its pushes are told apart from A's.
  defp viewer_b do
    parent = self()
    # socket/3 only from the test process, and it names the test process as
    # the transport: B's pushes must go to B's process
    socket = authed_socket("b")

    pid =
      spawn_link(fn ->
        {:ok, reply, _} = subscribe_and_join(%{socket | transport_pid: self()}, ObsFactorWeb.ObjectivesChannel, "objectives")
        send(parent, {:b_joined, reply})
        relay(parent)
      end)

    assert_receive {:b_joined, reply}, 2_000
    {pid, reply}
  end

  defp relay(parent) do
    receive do
      %Message{event: event, payload: payload} -> send(parent, {:b, event, payload})
    end

    relay(parent)
  end

  test "a pin and each act from one viewer reach the other as the row with its events" do
    {:ok, %{objectives: []}, a} = subscribe_and_join(authed_socket("a"), ObsFactorWeb.ObjectivesChannel, "objectives")
    {_b, %{objectives: []}} = viewer_b()

    ref = push(a, "pin", %{"node" => "blog", "title" => "blog feels slow", "note" => "p99?", "by" => "alice"})
    assert_reply ref, :ok, %{id: id, state: "open"}
    assert_receive {:b, "objective", %{id: ^id, state: "open", source: "pin", events: [%{kind: "pinned", by: "alice"}]}}, 2_000

    ref = push(a, "act", %{"id" => id, "action" => "look", "by" => "alice"})
    assert_reply ref, :ok, %{state: "looking"}
    assert_receive {:b, "objective", %{id: ^id, state: "looking", looking_by: "alice"}}, 2_000

    ref = push(a, "act", %{"id" => id, "action" => "done", "note" => "a cold cache", "by" => "alice"})
    assert_reply ref, :ok, %{state: "done"}
    assert_receive {:b, "objective", %{id: ^id, state: "done", done_by: "alice", note: "a cold cache", events: evs}}, 2_000
    assert Enum.map(evs, & &1.kind) == ["pinned", "looking", "crossed off"]

    # a rejoin (the panel after a reconnect) gets the same row in its list
    {_b2, %{objectives: [%{id: ^id, state: "done"}]}} = viewer_b()
  end

  test "a write over HTTP reaches channel viewers the same way" do
    {_b, _} = viewer_b()

    %{"id" => id} =
      build_conn()
      |> post("/login", %{"password" => Application.fetch_env!(:obs_factor, :password)})
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> dispatch(@endpoint, :post, "/api/objectives", Jason.encode!(%{"node" => "db", "title" => "pinned over http", "by" => "bob"}))
      |> json_response(201)

    assert_receive {:b, "objective", %{id: ^id, title: "pinned over http"}}, 2_000
  end

  test "act with an id that is not an integer is refused with the reason, nothing broadcast" do
    {:ok, _, a} = subscribe_and_join(authed_socket("a"), ObsFactorWeb.ObjectivesChannel, "objectives")
    {_b, _} = viewer_b()
    ref = push(a, "act", %{"id" => "1", "action" => "done"})
    assert_reply ref, :error, %{error: "act needs an integer id" <> _}
    refute_receive {:b, "objective", _}, 200
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
