defmodule ObsFactor.Connect do
  @moduledoc """
  "Connect an app" (docs/CONNECT.md): what to paste into a new Elixir app
  and its compose service so it reports to the floor, and a checklist of
  what the observer can already see of it.

  `generate/1` is pure: the same input gives the same snippets. It follows
  what a connected app on the box does today (blinks_backend: the vendored
  library, the child behind `config :<app>, factory_report: true` in
  `config/prod.exs`, `observer: true`, `FACTORY_REPORT_ACTIONS_TOKEN` from
  the stack's `OBS_FACTOR_ACTIONS_TOKEN`).

  `checklist/1` reads the observer's live state (`ObsFactor.Sources`, the
  merged topology) and asks the app's observer engine once, through
  `ObsFactor.ObserverProxy`, when its report answers.
  """

  alias ObsFactor.{Discovery, ObserverProxy, Sources}

  @app ~r/\A[a-z][a-z0-9_]{0,40}\z/
  @service ~r/\A[a-z0-9][a-z0-9_.-]{0,62}\z/
  @host ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/
  @database ~r/\A[a-z_][a-z0-9_]{0,62}\z/
  @kinds ["phoenix", "elixir"]
  @report_port 9568

  @doc """
  Checks and normalizes the form: `{:ok, input}` or `{:error, message}`.

  Fields: `app` (the OTP app, `my_app`), `service` (the compose service),
  `kind` (`phoenix` | `elixir`), and optional `label`, `hosts`,
  `databases` (comma separated), `platform`, `app_dir` (where the app's
  checkout is, for install.sh; default `../<app>`), `probe_port`.
  """
  def input(params) when is_map(params) do
    p = fn k -> params |> Map.get(k, "") |> to_string() |> String.trim() end
    app = p.("app")
    service = if p.("service") == "", do: String.replace(app, "_", "-"), else: p.("service")
    kind = if p.("kind") == "", do: "phoenix", else: p.("kind")
    hosts = list(p.("hosts"))
    databases = list(p.("databases"))
    label = p.("label")
    platform = p.("platform")
    probe_port = p.("probe_port")

    cond do
      not Regex.match?(@app, app) ->
        {:error, "app must be an OTP app name like my_app (lowercase, digits, _), got #{inspect(app)}"}

      not Regex.match?(@service, service) ->
        {:error, "service must be a compose service name like my-app, got #{inspect(service)}"}

      kind not in @kinds ->
        {:error, "kind must be phoenix or elixir, got #{inspect(kind)}"}

      (h = Enum.find(hosts, &(not Regex.match?(@host, &1)))) != nil ->
        {:error, "#{inspect(h)} is not a hostname"}

      (d = Enum.find(databases, &(not Regex.match?(@database, &1)))) != nil ->
        {:error, "#{inspect(d)} is not a Postgres database name"}

      String.contains?(label, ["\"", "\n"]) ->
        {:error, "label may not contain quotes or newlines"}

      platform != "" and not Regex.match?(~r/\A[a-z][a-z0-9-]*\z/, platform) ->
        {:error, "platform must be a platform id like main, got #{inspect(platform)}"}

      probe_port != "" and not match?({n, ""} when n in 1..65535, Integer.parse(probe_port)) ->
        {:error, "probe_port must be a port number, got #{inspect(probe_port)}"}

      true ->
        {:ok,
         %{
           app: app,
           service: service,
           kind: kind,
           module: Macro.camelize(app),
           label: if(label == "", do: nil, else: label),
           hosts: hosts,
           databases: databases,
           platform: if(platform == "", do: nil, else: platform),
           probe_port: if(probe_port == "", do: nil, else: String.to_integer(probe_port)),
           app_dir: if(p.("app_dir") == "", do: "../#{app}", else: p.("app_dir"))
         }}
    end
  end

  @doc "The report URL the observer will read: `http://<service>:9568/report`."
  def report_url(%{service: s}), do: "http://#{s}:#{@report_port}/report"

  @doc """
  Every snippet, as `[%{id, title, file, text, note}]`, in the order they
  are done. `file` is where it goes (nil for a command).
  """
  def generate(%{} = i) do
    [
      %{
        id: "install",
        title: "Vendor the library",
        file: nil,
        text: "packages/factory_report/install.sh #{shell(i.app_dir)}",
        note:
          "Run from the obs_factor checkout. Copies the library to #{i.app_dir}/vendor/factory_report " <>
            "and changes nothing else; run it again to update the copy. Commit vendor/."
      },
      %{
        id: "deps",
        title: "The dependency",
        file: "mix.exs",
        text: ~s({:factory_report, path: "vendor/factory_report"}),
        note: "In deps. Then `mix deps.get` once, so mix.lock has telemetry, plug, bandit and jason, and commit mix.lock."
      },
      %{
        id: "dockerfile",
        title: "Copy vendor/ before deps.get",
        file: "Dockerfile",
        text: "COPY mix.exs mix.lock ./\nCOPY vendor vendor\nRUN mix deps.get --only $MIX_ENV",
        note: "Mix reads vendor/factory_report/mix.exs while resolving dependencies: without the COPY the build stops at deps.get."
      },
      %{
        id: "application",
        title: "The child",
        file: "lib/#{i.app}/application.ex",
        text: application(i),
        note:
          "Add `++ factory_report()` to the children list. observer: true lets the observer read /observer " <>
            "without a report token; actions (gc, kill, restart) stay off until FACTORY_REPORT_ACTIONS_TOKEN is set."
      },
      %{
        id: "prod",
        title: "On in production only",
        file: "config/prod.exs",
        text: prod(i),
        note: "dev and test never bind :#{@report_port}. The second line is optional: one JSON object per log line on stdout."
      },
      %{
        id: "compose",
        title: "Labels and environment",
        file: "docker-compose.yml",
        text: compose(i),
        note:
          "The labels are what puts it on the floor: no topology edit, no observer restart. " <>
            "Do not publish #{@report_port} and do not route it through Caddy."
      }
    ]
  end

  defp application(i) do
    repos = if i.databases != [] and i.kind == "phoenix", do: ", repos: [#{i.module}.Repo]", else: ""

    """
    # The report the factory (obs_factor) reads, on :#{@report_port} inside
    # the compose network. On in production only (config/prod.exs).
    defp factory_report do
      if Application.get_env(:#{i.app}, :factory_report, false) do
        [{FactoryReport, app: :#{i.app}, port: #{@report_port}#{repos}, observer: true}]
      else
        []
      end
    end\
    """
  end

  defp prod(i) do
    """
    config :#{i.app}, factory_report: true

    config :logger, :default_handler, formatter: {FactoryReport.JSONFormatter, %{}}\
    """
  end

  defp compose(i) do
    labels =
      [
        {"obs_factor.report", report_url(i)},
        i.label && {"obs_factor.label", i.label},
        i.hosts != [] && {"obs_factor.hosts", Enum.join(i.hosts, ",")},
        i.databases != [] && {"obs_factor.databases", Enum.join(i.databases, ",")},
        i.platform && {"obs_factor.platform", i.platform},
        i.probe_port && {"obs_factor.probe", "http://#{i.service}:#{i.probe_port}/"}
      ]
      |> Enum.filter(& &1)
      |> Enum.map_join("\n", fn {k, v} -> ~s(      #{k}: "#{v}") end)

    """
      #{i.service}:
        # ... build, image, restart, mem_limit as before ...
        labels:
    #{labels}
        environment:
          # observer actions (gc, kill, restart a child), behind the token the
          # observer sends as OBSERVER_ACTIONS_TOKEN. Unset: they answer 403.
          FACTORY_REPORT_ACTIONS_TOKEN: ${OBS_FACTOR_ACTIONS_TOKEN}\
    """
  end

  ## The checklist

  @doc """
  What the observer sees of `input`'s app now: `[%{id, title, state, detail}]`
  with `state` `"ok"`, `"wait"` (not yet) or `"bad"` (seen, and wrong).
  Each step after the first waits on the one before it.
  """
  def checklist(%{} = i, opts \\ []) do
    docker = Keyword.get_lazy(opts, :docker, fn -> Sources.get(:docker) end)
    reports = Keyword.get_lazy(opts, :reports, fn -> Sources.get(:reports) end)
    topology = Keyword.get_lazy(opts, :topology, &ObsFactor.topology/0)
    engine = Keyword.get(opts, :engine, &engine/1)

    containers = case docker do %{ok: true, data: %{containers: cs}} -> cs; _ -> nil end
    {merged, problems} = if containers, do: Discovery.merge(topology, containers), else: {topology, []}

    mine = (containers || []) |> Enum.filter(&(&1.service == i.service and not &1.oneoff))
    running = Enum.find(mine, &(&1.state == "running"))
    node = Enum.find(merged.nodes, &(&1[:service] == i.service)) || Enum.find(merged.nodes, &(&1[:container] in Enum.map(mine, fn c -> c.name end)))

    container =
      cond do
        containers == nil -> step("container", "wait", "Docker is not answering: #{docker[:error]}")
        running -> step("container", "ok", "#{running.name}: #{running.status_text}")
        mine != [] -> step("container", "bad", "#{hd(mine).name} is #{hd(mine).state}")
        true -> step("container", "wait", "no container of compose service #{i.service} yet")
      end

    mention = Enum.find(problems, fn {_, text} -> Enum.any?(mine, &String.contains?(text, "container #{&1.name}")) end)

    floor =
      cond do
        container.state != "ok" -> step("floor", "wait", "after the container")
        node && node[:report] && mention -> step("floor", "bad", "node #{node.id}, but: #{elem(mention, 1)}")
        node && node[:report] -> step("floor", "ok", "node #{node.id}, report #{node.report}#{if node[:labelled_report], do: " (from its labels)", else: " (from the topology)"}")
        mention -> step("floor", "bad", elem(mention, 1))
        true -> step("floor", "wait", "the container has no obs_factor.report label (and no topology node with a report)")
      end

    report =
      cond do
        floor.state != "ok" -> step("report", "wait", "after the floor")
        not reports[:ok] -> step("report", "wait", "the reports source is not answering: #{reports[:error]}")
        true ->
          case reports.data[node.id] do
            nil -> step("report", "wait", "not read yet: the next tick reads it")
            %{ok: true} = r -> step("report", "ok", "#{node.report} answers (read at #{iso(r[:at])})")
            %{error: e} -> step("report", "bad", "#{node.report}: #{e}")
          end
      end

    observer =
      if report.state != "ok" do
        step("observer", "wait", "after the report")
      else
        case engine.(node.id) do
          {200, _} -> step("observer", "ok", "GET /observer answers")
          {status, %{"error" => e}} -> step("observer", "bad", "#{status}: #{e}")
          {status, _} -> step("observer", "bad", "answered #{status}")
        end
      end

    actions =
      if Application.get_env(:obs_factor, :observer_actions_token),
        do: step("actions", "ok", "OBSERVER_ACTIONS_TOKEN is set on the observer"),
        else: step("actions", "wait", "OBSERVER_ACTIONS_TOKEN is not set on the observer: actions answer 403 (reads still work)")

    [container, floor, report, observer, actions]
  end

  @titles %{
    "container" => "Docker lists a running container of the service",
    "floor" => "It is on the floor, with a report URL",
    "report" => "Its report answers",
    "observer" => "Its observer engine answers",
    "actions" => "Actions can reach it"
  }

  defp step(id, state, detail), do: %{id: id, title: @titles[id], state: state, detail: detail}

  defp engine(id) do
    ObserverProxy.call("GET", id, [], %{}, [])
  rescue
    e -> {502, %{"error" => Exception.message(e)}}
  end

  defp iso(%DateTime{} = t), do: t |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> iso()
  defp iso(_), do: "?"

  defp list(""), do: []
  defp list(s), do: s |> String.split(~r/[,\s]+/) |> Enum.reject(&(&1 == ""))

  defp shell(s), do: if(Regex.match?(~r|\A[A-Za-z0-9_./~-]+\z|, s), do: s, else: "'" <> String.replace(s, "'", "'\\''") <> "'")
end
