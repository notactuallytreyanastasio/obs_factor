defmodule ObsFactor.DeploysTest do
  @moduledoc """
  Deploys tied to commits: `.deployed` files in a temp directory, read the
  way the collector reads `/host-opt` on the box, kept in a real Postgres
  (as ObsFactor.WriteupTest), paired with restarts on the wire.
  """
  use ExUnit.Case, async: false

  alias ObsFactor.{Deploys, Tape, Wire}

  @url System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")

  @moduletag :tmp_dir

  defp write(root, rel, body) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  # the box's five, as `head -2 /opt/*/.deployed` printed them on 2026-11-23
  defp box(root) do
    write(root, "blog/.deployed", "9047a85+dirty  2026-11-19T09:22:31Z\n")
    write(root, "marginalia/.deployed", "d159fc5  2026-11-24T00:44:30Z\n")
    write(root, "obs_factor/.deployed", "5183284+dirty  2026-11-24T01:21:01Z\n")
    write(root, "tyler/.deployed", "dc95b30  2026-10-01T01:15:26Z\n")
  end

  defp nodes do
    [
      %{id: "app", service: "app", deployed: "blog/.deployed", repo: "notactuallytreyanastasio/blog"},
      %{id: "marginalia", service: "marginalia", repo: "notactuallytreyanastasio/marginalia"},
      %{id: "tyler", service: "tyler"},
      %{id: "obs-factor", service: "obs-factor", deployed: "obs_factor/.deployed"},
      # guessed, and not there: not an error
      %{id: "skyfeed", service: "skyfeed"},
      # named, and not there: an error
      %{id: "dave", service: "dave", deployed: "dave/.deployed"},
      %{id: "caddy", service: "caddy", deployed: false},
      %{id: "site-blimp", site: "blimp"}
    ]
  end

  defp no_github(_, _, _), do: flunk("GitHub was asked without a token")

  defp state(root, opts \\ []),
    do: Deploys.init_state(opts ++ [root: root, nodes: nodes(), github_token: nil, github: &no_github/3, db: :no_db])

  describe "parse" do
    test "what the deploy scripts write, a date alone, and what is not one" do
      assert {:ok, %{sha: "9047a85", dirty: true, at: at}} = Deploys.parse("9047a85+dirty  2026-11-19T09:22:31Z\n")
      assert DateTime.from_unix!(at, :millisecond) == ~U[2026-11-19 09:22:31.000Z]
      assert {:ok, %{sha: "d159fc5", dirty: false}} = Deploys.parse("d159fc5  2026-11-24T00:44:30Z")
      assert {:ok, %{at: day}} = Deploys.parse("9047a85+dirty 2026-11-19")
      assert DateTime.from_unix!(day, :millisecond) == ~U[2026-11-19 00:00:00.000Z]
      # git rev-parse failing writes "unknown": kept, never looked up
      assert {:ok, %{sha: "unknown"}} = Deploys.parse("unknown  2026-11-19T09:22:31Z")
      assert {:error, "not \"<sha>[+dirty] <time>\": \"\""} = Deploys.parse("")
      assert {:error, "\"yesterday\" is not an ISO 8601 time"} = Deploys.parse("9047a85 yesterday")
      assert {:error, _} = Deploys.parse("HEAD  2026-11-19T09:22:31Z")
    end
  end

  describe "the collector" do
    test "files: named, guessed from the service, turned off, none for a static site", %{tmp_dir: root} do
      assert Deploys.files(nodes(), root) == [
               {"app", Path.join(root, "blog/.deployed"), true, "notactuallytreyanastasio/blog"},
               {"marginalia", Path.join(root, "marginalia/.deployed"), false, "notactuallytreyanastasio/marginalia"},
               {"tyler", Path.join(root, "tyler/.deployed"), false, nil},
               {"obs-factor", Path.join(root, "obs_factor/.deployed"), true, nil},
               {"skyfeed", Path.join(root, "skyfeed/.deployed"), false, nil},
               {"dave", Path.join(root, "dave/.deployed"), true, nil}
             ]

      # an absolute path is used as it is
      assert [{"x", "/host-opt/blog/.deployed", true, nil}] = Deploys.files([%{id: "x", deployed: "/host-opt/blog/.deployed"}], root)
    end

    test "reads every file; a missing guess is absent, a missing named file and a bad line are errors", %{tmp_dir: root} do
      box(root)
      write(root, "tyler/.deployed", "garbage\n")
      {:ok, r, _} = Deploys.collect(state(root))

      assert Map.keys(r) |> Enum.sort() == ~w(app dave marginalia obs-factor tyler)
      assert %{sha: "9047a85", dirty: true, repo: "notactuallytreyanastasio/blog", node: "app"} = r["app"]
      refute Map.has_key?(r["app"], :subject)
      assert r["dave"].error == Path.join(root, "dave/.deployed") <> ": no such file or directory"
      assert r["tyler"].error =~ ~s(tyler/.deployed: not "<sha>[+dirty] <time>": "garbage")
    end

    test "with a token and a repo, the commit's subject; asked once per sha; an error is shown, not hidden", %{tmp_dir: root} do
      box(root)
      {:ok, calls} = Agent.start_link(fn -> [] end)

      gh = fn repo, sha, token ->
        Agent.update(calls, &[{repo, sha, token} | &1])
        if repo =~ "marginalia", do: {:error, "GitHub answered 404 for #{repo}@#{sha}: Not Found"}, else: {:ok, "Fix the feed"}
      end

      st = state(root, github_token: "ghp_test", github: gh)
      {:ok, r, st} = Deploys.collect(st)
      assert r["app"].subject == "Fix the feed"
      assert r["marginalia"].subject_error == "GitHub answered 404 for notactuallytreyanastasio/marginalia@d159fc5: Not Found"
      # no repo: never asked
      refute Map.has_key?(r["tyler"], :subject)

      {:ok, r2, _} = Deploys.collect(st)
      assert r2["app"].subject == "Fix the feed"
      # two shas asked, once each: the error is retried after ten minutes, not every tick
      assert Agent.get(calls, & &1) |> Enum.sort() == [
               {"notactuallytreyanastasio/blog", "9047a85", "ghp_test"},
               {"notactuallytreyanastasio/marginalia", "d159fc5", "ghp_test"}
             ]
    end

    test "attach: deployed on every node, and the fact the inspector shows", %{tmp_dir: root} do
      box(root)
      {:ok, r, _} = Deploys.collect(state(root))
      r = put_in(r, ["app", :subject], "Fix the feed")
      now = DateTime.to_unix(~U[2026-11-23 11:30:00Z], :millisecond)
      ns = [%{id: "app", facts: []}, %{id: "dave", facts: []}, %{id: "caddy", facts: []}]

      [app, dave, caddy] = Deploys.attach(ns, %{ok: true, data: r}, now)
      assert app.deployed.sha == "9047a85"
      assert app.deployed.url == "https://github.com/notactuallytreyanastasio/blog/commit/9047a85"
      assert app.facts == [%{label: "deployed", value: "9047a85+dirty 4d 2h ago · Fix the feed"}]
      assert dave.deployed.error =~ "no such file"
      assert [%{label: "deployed", value: "unreadable: " <> _}] = dave.facts
      assert caddy.deployed == nil and caddy.facts == []
      # the source failing: nil everywhere, nothing made up
      assert [%{deployed: nil}] = Deploys.attach([%{id: "app", facts: []}], %{ok: false, data: nil}, now)
    end
  end

  describe "GitHub" do
    # a local stand-in for api.github.com: the request as GitHub's docs
    # give it, answered with the shape GitHub answers
    defmodule FakeGitHub do
      import Plug.Conn

      def init(o), do: o

      def call(%{request_path: "/repos/o/r/commits/9047a85"} = conn, _) do
        if get_req_header(conn, "authorization") == ["Bearer ghp_test"] and get_req_header(conn, "accept") == ["application/vnd.github+json"],
          do: json(conn, 200, %{sha: "9047a85ffff", commit: %{message: "Ship the press\n\nlong body"}}),
          else: json(conn, 401, %{message: "Bad credentials"})
      end

      def call(conn, _), do: json(conn, 422, %{message: "No commit found for SHA: nope"})

      defp json(conn, s, b), do: conn |> put_resp_content_type("application/json") |> send_resp(s, Jason.encode!(b))
    end

    test "the first line of the message; GitHub's own message when it refuses" do
      {:ok, pid} = Bandit.start_link(plug: FakeGitHub, port: 0, ip: :loopback, startup_log: false)
      {:ok, {_, port}} = ThousandIsland.listener_info(pid)
      System.put_env("GITHUB_API_URL", "http://127.0.0.1:#{port}")
      on_exit(fn -> System.delete_env("GITHUB_API_URL") end)

      assert Deploys.github("o/r", "9047a85", "ghp_test") == {:ok, "Ship the press"}
      assert Deploys.github("o/r", "9047a85", "wrong") == {:error, "GitHub answered 401 for o/r@9047a85: Bad credentials"}
      # GitHub's answer for the sha the box's blog runs (9047a85, never pushed)
      assert Deploys.github("o/r", "nope", "ghp_test") == {:error, "GitHub has no commit nope in o/r (never pushed?)"}
    end
  end

  describe "kept in Postgres" do
    setup do
      db = Tape.db()
      start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
      Postgrex.query!(db, "DROP TABLE IF EXISTS deploys", [])
      Phoenix.PubSub.subscribe(ObsFactor.PubSub, Deploys.topic())
      %{db: db}
    end

    test "each deploy once, a new one when the file changes, broadcast when new", %{tmp_dir: root, db: db} do
      box(root)
      st = state(root, db: db)
      {:ok, _, st} = Deploys.collect(st)

      for _ <- 1..4, do: assert_receive({:deploy, %{node: _, sha: _}})
      refute_receive {:deploy, _}, 50

      # the observer restarting reads the same files: nothing new
      {:ok, _, _} = Deploys.collect(state(root, db: db))
      {:ok, _, st} = Deploys.collect(st)
      refute_receive {:deploy, _}, 50

      write(root, "marginalia/.deployed", "e0f1a2b  2026-11-23T12:00:00Z\n")
      {:ok, _, _} = Deploys.collect(st)
      assert_receive {:deploy, %{node: "marginalia", sha: "e0f1a2b", dirty: false, url: "https://github.com/notactuallytreyanastasio/marginalia/commit/e0f1a2b"}}

      {:ok, list} = Deploys.list(DateTime.to_unix(~U[2026-11-01 00:00:00Z], :millisecond), DateTime.to_unix(~U[2026-11-30 00:00:00Z], :millisecond), db)
      assert Enum.map(list, &{&1.node, &1.sha}) == [{"app", "9047a85"}, {"marginalia", "e0f1a2b"}, {"marginalia", "d159fc5"}, {"obs-factor", "5183284"}]
      # tyler's (2026-10-01) is outside the range
    end

    test "a subject that arrives later fills in the row", %{tmp_dir: root, db: db} do
      write(root, "blog/.deployed", "9047a85+dirty  2026-11-19T09:22:31Z\n")
      n = [%{id: "app", deployed: "blog/.deployed", repo: "o/blog"}]
      {:ok, _, _} = Deploys.collect(Deploys.init_state(root: root, nodes: n, github_token: nil, db: db))
      {:ok, _, _} = Deploys.collect(Deploys.init_state(root: root, nodes: n, github_token: "t", github: fn _, _, _ -> {:ok, "Ship it"} end, db: db))
      {:ok, [d]} = Deploys.list(0, DateTime.to_unix(~U[2027-01-01 00:00:00Z], :millisecond), db)
      assert d.subject == "Ship it"
    end
  end

  describe "the writeup" do
    setup do
      db = Tape.db()
      start_supervised!(Supervisor.child_spec({Postgrex, ObsFactor.Postgres.opts(@url, name: db, pool_size: 2, statement_timeout: "5000")}, id: db))
      Postgrex.query!(db, "DROP TABLE IF EXISTS deploys, writeups, wire_filters, tape_wire, tape_windows, tape_frames, objective_events, objectives", [])
      start_supervised!({ObsFactor.Objectives, db: db})
      start_supervised!({Tape, db: db, thin_first_ms: 3_600_000})
      _ = :sys.get_state(Tape)
      %{db: db}
    end

    test "the timeline has each deploy with its commit, by app and through a filter", %{tmp_dir: root, db: db} do
      at = DateTime.utc_now() |> DateTime.add(-300) |> DateTime.truncate(:second)
      write(root, "blog/.deployed", "9047a85+dirty  #{DateTime.to_iso8601(at)}\n")
      write(root, "tyler/.deployed", "dc95b30  #{DateTime.to_iso8601(at)}\n")
      gh = fn _, _, _ -> {:ok, "Ship the press"} end
      ns = [%{id: "app", deployed: "blog/.deployed", repo: "notactuallytreyanastasio/blog"}, %{id: "tyler", service: "tyler"}]
      {:ok, _, _} = Deploys.collect(Deploys.init_state(root: root, nodes: ns, github_token: "t", github: gh, db: db))

      to = System.system_time(:millisecond)
      {:ok, w} = ObsFactor.Writeup.build(from: to - 600_000, to: to, sections: ["timeline"])
      assert w.markdown =~ "| app | info · deploy | deployed 9047a85+dirty (Ship the press) — [9047a85](https://github.com/notactuallytreyanastasio/blog/commit/9047a85) |"
      assert w.markdown =~ "| tyler | info · deploy | deployed dc95b30 — .deployed names dc95b30 |"

      {:ok, only} = ObsFactor.Writeup.build(from: to - 600_000, to: to, sections: ["timeline"], apps: ["tyler"])
      refute only.markdown =~ "9047a85"
      {:ok, errs} = ObsFactor.Writeup.build(from: to - 600_000, to: to, sections: ["timeline"], spec: %{"kinds" => ["crash"]})
      refute errs.markdown =~ "deployed"
    end
  end

  describe "the wire" do
    defp snap(up, deployed) do
      %{"nodes" => [%{"id" => "app", "label" => "Phoenix blog", "inside" => %{"ok" => false}, "facts" => [],
                      "container" => %{"uptime_s" => up, "restarts" => 0}, "deployed" => deployed}]}
    end

    defp dep(sha, subject \\ nil), do: %{"sha" => sha, "dirty" => false, "at" => 1, "subject" => subject}

    defp ticks(snaps) do
      {items, _} =
        Enum.reduce(Enum.with_index(snaps), {[], Wire.new()}, fn {s, i}, {acc, w} ->
          {items, w} = Wire.observe(w, s, i * 5_000)
          {acc ++ Enum.map(items, &{i, &1.head, &1.text}), w}
        end)

      items
    end

    test "the restart, then .deployed a tick later (every deploy script's order): named as a deploy of that commit" do
      assert [{2, "container started again", _}, {3, "deployed 4b5c6d7 (Ship the press)", text}] =
               ticks([snap(1000, dep("9047a85")), snap(1005, dep("9047a85")), snap(3, dep("9047a85")), snap(8, dep("4b5c6d7", "Ship the press"))])

      assert text == "the container started again 5 s before; .deployed names 4b5c6d7"
    end

    test "both in one tick: one item; without a subject it says why there is none" do
      assert [{1, "deployed 4b5c6d7", text}] = ticks([snap(1000, dep("9047a85")), snap(3, dep("4b5c6d7"))])
      assert text =~ "no commit subject: GITHUB_TOKEN or the node's repo is not set"
    end

    test "not a deploy: .deployed changed without a restart, a restart long before, a first sighting, a gap" do
      # blog/deploy.sh writes .deployed even when it left the app running
      assert [] = ticks([snap(1000, dep("9047a85")), snap(1005, dep("4b5c6d7"))])
      # ten minutes and more after the restart: not this deploy
      long = for i <- 1..121, do: snap(3 + i * 5, dep("9047a85"))
      assert [{2, "container started again", _}] = ticks([snap(1000, dep("9047a85")), snap(1005, dep("9047a85")), snap(3, dep("9047a85"))] ++ long ++ [snap(9000, dep("4b5c6d7"))])
      # no .deployed before: what is there now is not news
      assert [{1, "container started again", _}] = ticks([snap(1000, nil), snap(3, dep("4b5c6d7"))])
      # the reading missing for a tick does not make the same sha look new
      assert [{3, "container started again", _}] = ticks([snap(1000, dep("9047a85")), snap(1005, nil), snap(1010, nil), snap(3, dep("9047a85"))])
    end
  end
end
