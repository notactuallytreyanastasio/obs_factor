defmodule ObsFactor.ReportsInsideTest do
  # Repo time per table and LiveView sessions alive per module: from the
  # report, through the collector's rates, to the snapshot's `inside`, per
  # node and per member. The last describe runs the real reporter.
  use ExUnit.Case, async: false

  alias ObsFactor.{Fixtures, Reports, Snapshot}

  defp t(table, count, us, errors \\ 0),
    do: %{"repo" => "Blog.Repo", "table" => table, "count" => count, "errors" => errors, "duration_us" => us}

  defp lv(views, extra \\ %{}) do
    Map.merge(
      %{
        "total" => views |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
        "views" => Enum.map(views, fn {v, n} -> %{"view" => v, "alive" => n} end),
        "views_cut" => 0,
        "processes" => 812,
        "walked" => 812,
        "walk_limit" => 20_000,
        "took_ms" => 1.25
      },
      extra
    )
  end

  defp doc(tables, liveviews) do
    Fixtures.report_doc() |> Map.put("tables", tables) |> Map.put("liveviews", liveviews)
  end

  defp validated!(doc) do
    assert {:ok, reading} = Reports.validate(doc)
    reading
  end

  # Two reads 5 s apart of the same process.
  defp twice(first, second) do
    {_, state} = Reports.step(Reports.new_node(), {:ok, validated!(first)}, Fixtures.now_ms() - 5_000)
    {data, _} = Reports.step(state, {:ok, validated!(second)}, Fixtures.now_ms())
    data
  end

  defp later(doc), do: update_in(doc, ["runtime", "uptime_s"], &(&1 + 5))

  defp inside(data) do
    {s, _} =
      Snapshot.build(
        Fixtures.topology(),
        Fixtures.sources(%{reports: Fixtures.ok(%{"app" => data})}),
        Snapshot.empty_memory(),
        Fixtures.now()
      )

    s |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("nodes") |> Enum.find(&(&1["id"] == "app")) |> Map.fetch!("inside")
  end

  describe "validate" do
    test "tables and liveviews as the reporter sends them" do
      r = validated!(doc([t("posts", 10, 5_000, 1), t(nil, 2, 100)], lv([{"BlogWeb.PostLive", 3}])))

      assert r.tables == [
               %{repo: "Blog.Repo", table: "posts", count: 10, errors: 1, duration_us: 5_000},
               %{repo: "Blog.Repo", table: nil, count: 2, errors: 0, duration_us: 100}
             ]

      assert r.liveviews == %{
               total: 3,
               views: [%{view: "BlogWeb.PostLive", alive: 3}],
               views_cut: 0,
               processes: 812,
               walked: 812,
               walk_limit: 20_000,
               took_ms: 1.25,
               unavailable: nil
             }
    end

    test "a reporter from before them: no tables, no liveviews" do
      r = validated!(Fixtures.report_doc())
      assert r.tables == [] and r.liveviews == nil and r.truncated.tables == 0
    end

    test "an older VM: total null, and why" do
      r = validated!(doc([], lv([], %{"total" => nil, "walked" => 0, "unavailable" => "needs OTP 26.2"})))
      assert %{total: nil, views: [], unavailable: "needs OTP 26.2"} = r.liveviews
    end

    test "wrong shapes fail the report, naming the place" do
      bad = fn d -> elem(Reports.validate(d), 1) end
      assert bad.(doc("x", nil)) == "tables is not a list"
      assert bad.(doc([%{"table" => "posts"}], nil)) == "tables[0].repo is missing"
      assert bad.(doc([t("posts", -1, 0)], nil)) == "tables[0].count is negative"
      assert bad.(doc([], [])) == "liveviews is not an object"
      assert bad.(doc([], lv([{"A", 1}]) |> put_in(["views", Access.at(0), "alive"], "1"))) == "liveviews.views[0].alive is not a number"
    end

    test "a reporter that does not bound itself: 100 tables (the most time), 100 views, the cut counted" do
      tables = for i <- 1..130, do: t("t#{i}", 1, i)
      views = for i <- 1..120, do: {"V#{i}", i}
      r = validated!(doc(tables, lv(views, %{"views_cut" => 2})) |> Map.put("truncated", %{"tables" => 4}))

      assert length(r.tables) == 100 and hd(r.tables).table == "t130" and List.last(r.tables).table == "t31"
      assert r.truncated.tables == 34
      assert length(r.liveviews.views) == 100 and hd(r.liveviews.views) == %{view: "V120", alive: 120}
      assert r.liveviews.views_cut == 22
    end
  end

  describe "rates over the window" do
    test "queries, rate, average and total time over the window; a new table counts from zero" do
      first = doc([t("posts", 100, 50_000), t("users", 10, 1_000)], lv([]))
      second = later(doc([t("posts", 150, 75_000, 5), t("users", 10, 1_000), t("new", 4, 2_000)], lv([])))
      data = twice(first, second)

      assert Enum.find(data.tables, &(&1.table == "posts")) == %{
               repo: "Blog.Repo",
               table: "posts",
               count: 150,
               errors: 5,
               duration_us: 75_000,
               window_s: 5.0,
               queries: 50,
               rate: 10.0,
               err_rate: 1.0,
               avg_ms: 0.5,
               total_ms: 25.0
             }

      assert %{queries: 0, rate: 0.0, avg_ms: nil, total_ms: 0.0} = Enum.find(data.tables, &(&1.table == "users"))
      assert %{queries: 4, total_ms: 2.0, avg_ms: 0.5} = Enum.find(data.tables, &(&1.table == "new"))
    end

    test "a table whose totals went backwards is a restart: every window value nil" do
      data = twice(doc([t("posts", 100, 50_000)], nil), later(doc([t("posts", 3, 900)], nil)))
      assert data.restart
      assert [%{queries: nil, rate: nil, avg_ms: nil, total_ms: nil, window_s: nil}] = data.tables
    end

    test "after a read whose tables were cut, a table not seen before has no window yet" do
      first = doc([t("posts", 1, 1)], nil) |> Map.put("truncated", %{"tables" => 1})
      data = twice(first, later(doc([t("posts", 2, 2), t("hidden", 9, 9)], nil)))
      assert %{queries: nil} = Enum.find(data.tables, &(&1.table == "hidden"))
      assert %{queries: 1} = Enum.find(data.tables, &(&1.table == "posts"))
    end
  end

  describe "the snapshot's inside" do
    test "the 15 tables with the most time over the window, rounded; the cut counted; liveviews as reported" do
      # Busiest since start is not busiest now: t1 has the most time in all,
      # t20 the most in the window.
      first = doc(for(i <- 1..20, do: t("t#{i}", 1_000, (21 - i) * 1_000_000)), lv([{"BlogWeb.PostLive", 3}, {"BlogWeb.Nav", 3}]))

      second =
        later(doc(for(i <- 1..20, do: t("t#{i}", 1_000 + i, (21 - i) * 1_000_000 + i * 1_000)), lv([{"BlogWeb.PostLive", 2}])))

      inside = inside(twice(first, second))

      assert length(inside["tables"]) == 15
      assert Enum.map(inside["tables"], & &1["table"]) == Enum.map(20..6//-1, &"t#{&1}")
      assert inside["truncated"]["tables"] == 5

      assert hd(inside["tables"]) == %{
               "repo" => "Blog.Repo",
               "table" => "t20",
               "count" => 1_020,
               "errors" => 0,
               "duration_us" => 1_020_000,
               "window_s" => 5.0,
               "queries" => 20,
               "rate" => 4.0,
               "err_rate" => 0.0,
               "avg_ms" => 1.0,
               "total_ms" => 20.0
             }

      assert inside["liveviews"] == %{
               "total" => 2,
               "views" => [%{"view" => "BlogWeb.PostLive", "alive" => 2}],
               "views_cut" => 0,
               "processes" => 812,
               "walked" => 812,
               "walk_limit" => 20_000,
               "took_ms" => 1.25,
               "unavailable" => nil
             }
    end

    test "one read: no window yet, so the most time since the process started" do
      {data, _} =
        Reports.step(Reports.new_node(), {:ok, validated!(doc([t("a", 1, 10), t("b", 1, 30)], nil))}, Fixtures.now_ms())

      assert [%{"table" => "b", "total_ms" => nil, "rate" => nil}, %{"table" => "a"}] = inside(data)["tables"]
      assert inside(data)["liveviews"] == nil
    end

    test "a scaled service: the node sums its members' tables and sessions; each member keeps its own" do
      a = twice(doc([t("posts", 10, 10_000)], lv([{"V", 2}, {"W", 1}])), later(doc([t("posts", 20, 30_000)], lv([{"V", 2}, {"W", 1}]))))
      b = twice(doc([t("posts", 5, 1_000)], lv([{"V", 4}])), later(doc([t("posts", 15, 11_000), t(nil, 1, 0)], lv([{"V", 4}]))))
      down = %{ok: false, error: "connection refused", at: nil}

      inside = inside(Reports.combine([{"10.0.0.2", a}, {"10.0.0.3", b}, {"10.0.0.4", down}]))

      posts = Enum.find(inside["tables"], &(&1["table"] == "posts"))
      assert %{"count" => 35, "queries" => 20, "rate" => 4.0, "total_ms" => 30.0, "avg_ms" => 1.5} = posts
      assert %{"queries" => 1} = Enum.find(inside["tables"], &(&1["table"] == nil))

      assert %{"total" => 7, "views" => [%{"view" => "V", "alive" => 6}, %{"view" => "W", "alive" => 1}], "walked" => 1624} =
               inside["liveviews"]

      [m2, m3, m4] = inside["members"]
      assert [%{"table" => "posts", "queries" => 10, "total_ms" => 20.0}] = m2["tables"]
      assert m2["liveviews"]["total"] == 3
      assert m3["liveviews"]["views"] == [%{"view" => "V", "alive" => 4}]
      assert length(m3["tables"]) == 2
      assert %{"ok" => false, "tables" => nil, "liveviews" => nil} = m4
    end
  end

  describe "the real reporter" do
    defmodule Repo do
      def config, do: [telemetry_prefix: [:inside_test, :repo]]
    end

    defp query(source, ms) do
      native = System.convert_time_unit(ms, :millisecond, :native)
      :telemetry.execute([:inside_test, :repo, :query], %{total_time: native}, %{repo: Repo, source: source, result: {:ok, %{}}})
    end

    test "its report over HTTP, read twice, reaches the snapshot" do
      start_supervised!({FactoryReport, app: :obs_factor, port: 0, repos: [Repo]})
      url = "http://127.0.0.1:#{FactoryReport.port()}/report"

      query("posts", 2)
      assert {:ok, first} = Reports.fetch(url, nil)
      for _ <- 1..3, do: query("posts", 4)
      query("comments", 2)
      query(nil, 1)
      assert {:ok, second} = Reports.fetch(url, nil)

      {_, state} = Reports.step(Reports.new_node(), {:ok, first}, Fixtures.now_ms() - 5_000)
      {data, _} = Reports.step(state, {:ok, second}, Fixtures.now_ms())
      inside = inside(data)

      name = inspect(Repo)

      assert [
               %{"repo" => ^name, "table" => "posts", "count" => 4, "queries" => 3, "total_ms" => 12.0, "avg_ms" => 4.0},
               %{"table" => "comments", "queries" => 1, "total_ms" => 2.0},
               %{"table" => nil, "queries" => 1}
             ] = inside["tables"]

      # This VM runs no LiveView: none alive, every process walked.
      assert %{"total" => 0, "views" => [], "unavailable" => nil, "walk_limit" => 20_000} = inside["liveviews"]
      assert inside["liveviews"]["walked"] == inside["liveviews"]["processes"]
    end
  end
end
