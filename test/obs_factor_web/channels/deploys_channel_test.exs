defmodule ObsFactorWeb.DeploysChannelTest do
  @moduledoc "What the timeline's deploy marks (deploys.js) rely on: the `deploys` channel."
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactor.{Deploys, Tape}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  @moduletag :tmp_dir

  test "without the objectives database: the join says why, with no deploys" do
    assert {:ok, %{deploys: [], error: "no deploy history: OBJECTIVES_PG_URL is not set"}, _} =
             subscribe_and_join(authed_socket("a"), ObsFactorWeb.DeploysChannel, "deploys")
  end

  test "the join lists the last 31 days, a new deploy is pushed, list answers a range", %{tmp_dir: root} do
    db = Tape.db()
    start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
    Postgrex.query!(db, "DROP TABLE IF EXISTS deploys", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = Path.join(root, "blog/.deployed")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "9047a85+dirty  #{DateTime.to_iso8601(DateTime.add(now, -3600))}\n")
    st = Deploys.init_state(root: root, nodes: [%{id: "app", deployed: "blog/.deployed", repo: "o/blog"}], github_token: nil, db: db)
    {:ok, _, st} = Deploys.collect(st)

    {:ok, %{deploys: [%{node: "app", sha: "9047a85", dirty: true, url: "https://github.com/o/blog/commit/9047a85"}]}, socket} =
      subscribe_and_join(authed_socket("a"), ObsFactorWeb.DeploysChannel, "deploys")

    File.write!(path, "4b5c6d7  #{DateTime.to_iso8601(now)}\n")
    {:ok, _, _} = Deploys.collect(st)
    assert_push "deploy", %{node: "app", sha: "4b5c6d7", dirty: false}
    refute_push "deploy", _, 50

    t = DateTime.to_unix(now, :millisecond)
    ref = push(socket, "list", %{"from" => t - 60_000, "to" => t + 1})
    assert_reply ref, :ok, %{deploys: [%{sha: "4b5c6d7"}]}

    ref = push(socket, "list", %{"from" => 0, "to" => t})
    assert_reply ref, :error, %{error: "deploys: cannot \"list\"" <> _}
  end
end
