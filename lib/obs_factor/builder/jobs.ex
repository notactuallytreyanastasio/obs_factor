defmodule ObsFactor.Builder.Jobs do
  @moduledoc """
  Every build job, in memory and on disk (`<state>/jobs/<id>.json`, plus the
  full log in `<id>.log`), so a builder restart keeps the history. A job
  that was running when the builder stopped is marked failed on boot: its
  step was interrupted and nobody knows how far it got.

  A job is a plain string-keyed map (it is JSON on disk and on the wire):
  `id name label fqdn mode repo ref status step steps error commit plan
  plan_summary created_at finished_at`. `steps` is
  `[%{"name", "state", "note", "started_at", "finished_at"}]` with state
  `pending | running | done | failed`.
  """

  use GenServer
  require Logger

  alias ObsFactor.Builder.{Name, Runner, Source}

  @name ~r/^[a-z][a-z0-9-]{0,28}[a-z0-9]$/
  @steps %{
    "route" => ~w(name route check),
    "github" => ~w(name route source recipe image service check)
  }
  @log_keep 400

  def modes, do: Map.keys(@steps)

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  def config, do: :persistent_term.get({__MODULE__, :config})

  def create(params), do: GenServer.call(__MODULE__, {:create, params})
  def list, do: GenServer.call(__MODULE__, :list)
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  # Called by the runner.
  def step(id, step, state, note \\ nil), do: GenServer.cast(__MODULE__, {:step, id, step, state, note})
  def log(id, step, line), do: GenServer.cast(__MODULE__, {:log, id, step, line})
  def put(id, fields), do: GenServer.cast(__MODULE__, {:put, id, fields})
  def finish(id, status, error \\ nil), do: GenServer.cast(__MODULE__, {:finish, id, status, error})

  ## Server

  @impl true
  def init(cfg) do
    :persistent_term.put({__MODULE__, :config}, cfg)
    for d <- [cfg.jobs_dir, cfg.apps_dir, cfg.caddy_dir], do: File.mkdir_p!(d)
    Name.ensure_file!(cfg)

    jobs =
      for f <- Path.wildcard(Path.join(cfg.jobs_dir, "*.json")), into: %{} do
        job = f |> File.read!() |> Jason.decode!()
        job = if job["status"] == "running", do: interrupted(job), else: job
        {job["id"], Map.put(job, "log", tail_log(cfg, job["id"]))}
      end

    Enum.each(jobs, fn {_, j} -> persist(cfg, j) end)
    {:ok, %{cfg: cfg, jobs: jobs, tasks: %{}}}
  end

  @impl true
  def handle_call({:create, params}, _from, state) do
    case validate(params, state) do
      {:ok, job} ->
        persist(state.cfg, job)
        task = Task.Supervisor.async_nolink(ObsFactor.TaskSupervisor, fn -> Runner.run(job) end)
        Logger.info("build #{job["id"]}: started (#{job["mode"]} #{job["fqdn"]})")

        {:reply, {:ok, summary(job)},
         %{state | jobs: Map.put(state.jobs, job["id"], job), tasks: Map.put(state.tasks, task.ref, job["id"])}}

      {:error, _} = e ->
        {:reply, e, state}
    end
  end

  def handle_call(:list, _from, state) do
    jobs = state.jobs |> Map.values() |> Enum.sort_by(& &1["created_at"], :desc) |> Enum.map(&summary/1)
    {:reply, jobs, state}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.fetch(state.jobs, id), state}
  end

  @impl true
  def handle_cast({:step, id, step, st, note}, state) do
    now = now()

    state =
      update(state, id, fn job ->
        steps =
          Enum.map(job["steps"], fn
            %{"name" => ^step} = s ->
              s
              |> Map.put("state", st)
              |> then(&if(note, do: Map.put(&1, "note", note), else: &1))
              |> then(&if(st == "running", do: Map.put(&1, "started_at", now), else: Map.put(&1, "finished_at", now)))

            s ->
              s
          end)

        %{job | "steps" => steps, "step" => step}
      end, true)

    {:noreply, state}
  end

  def handle_cast({:log, id, step, line}, state) do
    entry = %{"t" => now(), "step" => step, "line" => String.slice(line, 0, 2000)}
    File.write(log_path(state.cfg, id), Jason.encode!(entry) <> "\n", [:append])
    {:noreply, update(state, id, &Map.update!(&1, "log", fn l -> Enum.take(l ++ [entry], -@log_keep) end), false)}
  end

  def handle_cast({:put, id, fields}, state), do: {:noreply, update(state, id, &Map.merge(&1, fields), true)}

  def handle_cast({:finish, id, status, error}, state) do
    Logger.info("build #{id}: #{status}#{if error, do: ": " <> error, else: ""}")
    {:noreply, update(state, id, &Map.merge(&1, %{"status" => status, "error" => error, "finished_at" => now()}), true)}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  # The runner crashed: the job must not stay "running" forever.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.tasks, ref) do
    id = state.tasks[ref]
    msg = "builder crashed: #{Exception.format_exit(reason) |> String.slice(0, 300)}"
    Logger.error("build #{id}: #{msg}")

    state =
      update(state, id, fn job ->
        if job["status"] == "running", do: fail_running(job, msg), else: job
      end, true)

    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  ## Helpers

  defp validate(params, state) do
    cfg = state.cfg
    name = params["name"]
    mode = params["mode"] || "github"
    repo = params["repo"]
    ref = blank(params["ref"])
    label = blank(params["label"])
    busy = Enum.find(Map.values(state.jobs), &(&1["name"] == name and &1["status"] == "running"))

    cond do
      not (is_binary(name) and Regex.match?(@name, name) and not String.contains?(name, "--")) ->
        {:error, "name must be 2-30 lowercase letters, digits and single hyphens, starting with a letter"}

      busy ->
        {:error, "#{name} is already being built (#{busy["id"]})"}

      not Map.has_key?(@steps, mode) ->
        {:error, "mode must be one of #{Enum.join(modes(), ", ")}"}

      mode == "github" and not Source.valid_repo?(repo) ->
        {:error, "repo must be https://github.com/<owner>/<repo>"}

      mode == "github" and not Source.valid_ref?(ref) ->
        {:error, "ref is not a branch or tag name"}

      label && String.length(label) > 40 ->
        {:error, "label is longer than 40 characters"}

      true ->
        ts = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")

        {:ok,
         %{
           "id" => "#{name}-#{ts}",
           "name" => name,
           "label" => label || name,
           "fqdn" => Name.fqdn(cfg, name),
           "mode" => mode,
           "repo" => if(mode == "github", do: String.trim_trailing(repo, "/")),
           "ref" => ref,
           "status" => "running",
           "step" => hd(@steps[mode]),
           "steps" => for(s <- @steps[mode], do: %{"name" => s, "state" => "pending", "note" => nil}),
           "error" => nil,
           "commit" => nil,
           "plan" => nil,
           "plan_summary" => nil,
           "created_at" => now(),
           "finished_at" => nil,
           "log" => []
         }}
    end
  end

  defp blank(nil), do: nil
  defp blank(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp blank(_), do: nil

  defp summary(job), do: Map.drop(job, ["log", "plan"])

  defp update(state, id, fun, persist?) do
    case state.jobs do
      %{^id => job} ->
        job = fun.(job)
        if persist?, do: persist(state.cfg, job)
        %{state | jobs: Map.put(state.jobs, id, job)}

      _ ->
        state
    end
  end

  defp interrupted(job), do: fail_running(job, "the builder stopped while this step ran")

  defp fail_running(job, msg) do
    steps = Enum.map(job["steps"], fn s -> if s["state"] == "running", do: %{s | "state" => "failed"}, else: s end)
    %{job | "steps" => steps, "status" => "failed", "error" => msg, "finished_at" => now()}
  end

  defp persist(cfg, job) do
    path = Path.join(cfg.jobs_dir, "#{job["id"]}.json")
    File.write!(path <> ".tmp", Jason.encode!(Map.delete(job, "log"), pretty: true))
    File.rename!(path <> ".tmp", path)
  end

  defp log_path(cfg, id), do: Path.join(cfg.jobs_dir, "#{id}.log")

  @doc "The whole log of job `id` from its file, up to the last #{20_000} lines; nil if there is no such job."
  def full_log(id) do
    cfg = config()

    if Regex.match?(~r/^[a-z0-9-]{1,80}$/, id) do
      case File.read(log_path(cfg, id)) do
        {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.take(-20_000) |> Enum.map(&Jason.decode!/1)
        _ -> nil
      end
    end
  end

  defp tail_log(cfg, id) do
    case File.read(log_path(cfg, id)) do
      {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.take(-@log_keep) |> Enum.map(&Jason.decode!/1)
      _ -> []
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
