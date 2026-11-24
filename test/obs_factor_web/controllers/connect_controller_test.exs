defmodule ObsFactorWeb.ConnectControllerTest do
  # Shares the application's topology and Sources.
  use ObsFactorWeb.ConnCase, async: false

  @password "correct horse battery staple"

  setup %{conn: conn} do
    on_exit(fn -> ObsFactor.Sources.clear() end)
    {:ok, conn: conn |> post("/login", %{"password" => @password}) |> recycle()}
  end

  defp put_source(name, data) do
    ObsFactor.Sources.put(name, %{ok: true, at: DateTime.utc_now(), error: nil, data: data,
                                  attempted_at: System.system_time(:millisecond), max_age_ms: 60_000})
  end

  test "behind the session, and a bad form is a 422 naming the field" do
    assert build_conn() |> get("/api/connect?app=x") |> json_response(401)
    conn = Phoenix.ConnTest.build_conn() |> post("/login", %{"password" => @password}) |> recycle()
    assert %{"error" => "kind must be phoenix or elixir, got \"go\""} = conn |> get("/api/connect?app=x&kind=go") |> json_response(422)
  end

  test "an app that connects by its labels: the reports collector reads it, and the checklist goes green", %{conn: conn} do
    # a real reporter, as a connected app runs it (observer: true, no token)
    start_supervised!({FactoryReport, app: :obs_factor, port: 0, observer: true})
    url = "http://127.0.0.1:#{FactoryReport.port()}/report"

    container = %{id: "c1", name: "blog-ledger-1", image: "ledger", state: "running", status_text: "Up 1 minute",
                  service: "ledger", project: "blog", oneoff: false, labels: %{"report" => url, "label" => "Ledger"}}

    put_source(:docker, %{containers: [container]})

    # the collector adds the labelled target to its static ones (none here)
    {:ok, data, _} = ObsFactor.Reports.collect(ObsFactor.Reports.init_state(targets: [], token: nil))
    assert %{"ledger" => %{ok: true}} = data
    put_source(:reports, data)

    body = conn |> get("/api/connect?app=ledger&service=ledger&label=Ledger") |> json_response(200)
    states = Map.new(body["checklist"], &{&1["id"], &1["state"]})
    assert %{"container" => "ok", "floor" => "ok", "report" => "ok", "observer" => "ok"} = states
    assert body["report_url"] == "http://ledger:9568/report"
    assert Enum.map(body["snippets"], & &1["id"]) == ~w(install deps dockerfile application prod compose)

    # and the floor's pass-through reaches its engine, though no topology file names it
    assert %{"observer" => 1} = conn |> recycle() |> get("/api/nodes/ledger/observer") |> json_response(200)
  end
end
