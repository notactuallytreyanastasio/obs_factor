defmodule ObsFactor.ConnectTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Connect

  @form %{"app" => "ledger_app", "service" => "ledger", "kind" => "phoenix", "label" => "Ledger",
          "hosts" => "ledger.bobbby.online", "databases" => "ledger_prod"}

  defp snippets(form) do
    {:ok, i} = Connect.input(form)
    Map.new(Connect.generate(i), &{&1.id, &1})
  end

  describe "the form" do
    test "defaults: service from the app, kind phoenix, app_dir beside obs_factor" do
      assert {:ok, %{service: "my-app", kind: "phoenix", module: "MyApp", app_dir: "../my_app", hosts: [], label: nil}} =
               Connect.input(%{"app" => "my_app"})
    end

    test "every bad field is named" do
      assert {:error, "app must be" <> _} = Connect.input(%{"app" => "MyApp"})
      assert {:error, "service must be" <> _} = Connect.input(%{"app" => "a", "service" => "A B"})
      assert {:error, "kind must be phoenix or elixir, got \"rails\""} = Connect.input(%{"app" => "a", "kind" => "rails"})
      assert {:error, "\"-bad-.test\" is not a hostname"} = Connect.input(%{"app" => "a", "hosts" => "ok.test,-bad-.test"})
      assert {:error, "\"Ledger-Prod\" is not a Postgres database name"} = Connect.input(%{"app" => "a", "databases" => "Ledger-Prod"})
      assert {:error, "label may not contain" <> _} = Connect.input(%{"app" => "a", "label" => ~s(say "hi")})
      assert {:error, "probe_port must be" <> _} = Connect.input(%{"app" => "a", "probe_port" => "99999"})
    end
  end

  describe "what it generates" do
    test "the install command and the dependency" do
      s = snippets(@form)
      assert s["install"].text == "packages/factory_report/install.sh ../ledger_app"
      assert s["deps"].text == ~s({:factory_report, path: "vendor/factory_report"})
      assert s["dockerfile"].text == "COPY mix.exs mix.lock ./\nCOPY vendor vendor\nRUN mix deps.get --only $MIX_ENV"

      # a path with a space is quoted for the shell
      assert snippets(Map.put(@form, "app_dir", "~/code/my ledger"))["install"].text ==
               "packages/factory_report/install.sh '~/code/my ledger'"
    end

    test "the child, with observer: true and the repo when there is a database" do
      s = snippets(@form)
      assert s["application"].file == "lib/ledger_app/application.ex"

      assert s["application"].text == """
             # The report the factory (obs_factor) reads, on :9568 inside
             # the compose network. On in production only (config/prod.exs).
             defp factory_report do
               if Application.get_env(:ledger_app, :factory_report, false) do
                 [{FactoryReport, app: :ledger_app, port: 9568, repos: [LedgerApp.Repo], observer: true}]
               else
                 []
               end
             end\
             """

      plain = snippets(%{"app" => "worker", "kind" => "elixir"})
      assert plain["application"].text =~ "[{FactoryReport, app: :worker, port: 9568, observer: true}]"
    end

    test "config/prod.exs" do
      assert snippets(@form)["prod"].text ==
               "config :ledger_app, factory_report: true\n\nconfig :logger, :default_handler, formatter: {FactoryReport.JSONFormatter, %{}}"
    end

    test "the compose labels and environment, which Discovery reads back" do
      text = snippets(Map.merge(@form, %{"platform" => "main", "probe_port" => "4000"}))["compose"].text

      assert text == """
               ledger:
                 # ... build, image, restart, mem_limit as before ...
                 labels:
                   obs_factor.report: "http://ledger:9568/report"
                   obs_factor.label: "Ledger"
                   obs_factor.hosts: "ledger.bobbby.online"
                   obs_factor.databases: "ledger_prod"
                   obs_factor.platform: "main"
                   obs_factor.probe: "http://ledger:4000/"
                 environment:
                   # observer actions (gc, kill, restart a child), behind the token the
                   # observer sends as OBSERVER_ACTIONS_TOKEN. Unset: they answer 403.
                   FACTORY_REPORT_ACTIONS_TOKEN: ${OBS_FACTOR_ACTIONS_TOKEN}\
             """

      # round trip: the labels, as Docker.Parse hands them over, put it on the floor
      labels =
        for [_, k, v] <- Regex.scan(~r/obs_factor\.([a-z]+): "([^"]*)"/, text), into: %{}, do: {k, v}

      c = %{id: "x", name: "blog-ledger-1", image: "i", state: "running", status_text: "Up", service: "ledger",
            project: "blog", oneoff: false, labels: labels}

      topology = %{platforms: [%{id: "main", label: "m"}], nodes: [], edges: []}
      {%{nodes: [n]}, []} = ObsFactor.Discovery.merge(topology, [c])

      assert %{id: "ledger", label: "Ledger", report: "http://ledger:9568/report", hosts: ["ledger.bobbby.online"],
               databases: ["ledger_prod"], platform: "main", probe: "http://ledger:4000/"} = n
    end
  end

  describe "the checklist" do
    @topology %{platforms: [%{id: "main", label: "m"}], nodes: [], edges: []}

    defp c(state, labels),
      do: %{id: "x", name: "blog-ledger-1", image: "i", state: state, status_text: "Up 2 minutes", service: "ledger",
            project: "blog", oneoff: false, labels: labels}

    defp ok(data), do: %{ok: true, at: nil, error: nil, data: data}

    defp check(containers, reports, engine \\ fn _ -> flunk("the engine must not be asked") end) do
      {:ok, i} = Connect.input(@form)
      docker = if containers == :down, do: %{ok: false, error: "connection refused", data: nil}, else: ok(%{containers: containers})
      Connect.checklist(i, docker: docker, reports: reports, topology: @topology, engine: engine)
      |> Map.new(&{&1.id, {&1.state, &1.detail}})
    end

    test "nothing yet: every step waits on the one before" do
      s = check([], ok(%{}))
      assert s["container"] == {"wait", "no container of compose service ledger yet"}
      assert s["floor"] == {"wait", "after the container"}
      assert s["report"] == {"wait", "after the floor"}
      assert s["observer"] == {"wait", "after the report"}

      assert check(:down, ok(%{}))["container"] == {"wait", "Docker is not answering: connection refused"}
    end

    test "a stopped container is bad; a running one without the label waits on the label" do
      assert check([c("exited", %{})], ok(%{}))["container"] == {"bad", "blog-ledger-1 is exited"}
      s = check([c("running", %{})], ok(%{}))
      assert s["container"] == {"ok", "blog-ledger-1: Up 2 minutes"}
      assert {"wait", "the container has no obs_factor.report label" <> _} = s["floor"]
    end

    test "a bad label is shown with the reason Discovery gave" do
      s = check([c("running", %{"report" => "ledger:9568"})], ok(%{}))
      assert s["floor"] == {"bad", "container blog-ledger-1: not placed: obs_factor.report \"ledger:9568\" is not an http(s) URL"}
    end

    test "labelled, reporting, and the engine answering: all green but actions" do
      labels = %{"report" => "http://ledger:9568/report"}
      at = ~U[2026-11-23 10:00:00Z]

      s = check([c("running", labels)], ok(%{}))
      assert s["floor"] == {"ok", "node ledger, report http://ledger:9568/report (from its labels)"}
      assert s["report"] == {"wait", "not read yet: the next tick reads it"}

      s = check([c("running", labels)], ok(%{"ledger" => %{ok: false, error: "connection refused", at: nil}}))
      assert s["report"] == {"bad", "http://ledger:9568/report: connection refused"}
      # the URL the node really has, not the one the form would generate
      other = check([c("running", %{"report" => "http://ledger:4001/r"})], ok(%{"ledger" => %{ok: false, error: "refused", at: nil}}))
      assert other["report"] == {"bad", "http://ledger:4001/r: refused"}

      engine = fn "ledger" -> {403, %{"error" => "observer reads need a token"}} end
      s = check([c("running", labels)], ok(%{"ledger" => %{ok: true, at: at}}), engine)
      assert s["report"] == {"ok", "http://ledger:9568/report answers (read at 2026-11-23T10:00:00Z)"}
      assert s["observer"] == {"bad", "403: observer reads need a token"}

      s = check([c("running", labels)], ok(%{"ledger" => %{ok: true, at: at}}), fn "ledger" -> {200, %{}} end)
      assert s["observer"] == {"ok", "GET /observer answers"}
    end
  end
end
