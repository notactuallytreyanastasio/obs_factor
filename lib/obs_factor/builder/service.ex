defmodule ObsFactor.Builder.Service do
  @moduledoc """
  Primitives 5 and 6, the image and the service: `docker build` from the
  plan, then one container on the stack's network, labelled so the observer
  places it (`obs_factor.*`, see `ObsFactor.Labelled`).

  Secrets the plan names are generated once per app and kept in
  `<state>/apps/<name>/secrets.env` (mode 600), passed with `--env-file`, so
  a rebuild keeps the same tokens and no secret is ever on a command line,
  in a label or in the job log.
  """

  alias ObsFactor.Builder.Shell

  def container(name), do: "obsbuild-#{name}"
  def image(name, commit), do: "obsbuild/#{name}:#{String.slice(commit, 0, 12)}"

  # BuildKit, always: Dockerfiles in the wild use RUN --mount (deciduous's
  # does), which the legacy builder rejects. The Docker CLI only finds buildx
  # if it is configured to (Homebrew installs the plugin where the CLI does
  # not look), so BUILDER_BUILDX can name the plugin binary, which runs
  # standalone against the current context (verified with buildx 0.35).
  def build(cfg, name, commit, dir, plan, log) do
    tag = image(name, commit)
    target = ["build", "--load", "--progress=plain", "-t", tag, "-f", Path.join(dir, plan["dockerfile"]), Path.expand(plan["context"], dir)]
    {exe, args} = if cfg.buildx, do: {cfg.buildx, target}, else: {"docker", ["buildx" | target]}

    case Shell.run(exe, args, [timeout: 45 * 60_000], log) do
      {:ok, _} -> {:ok, tag}
      {:error, msg, tail} -> {:error, "docker build: #{msg}: #{tail |> Enum.take(-2) |> Enum.join(" | ")}"}
    end
  end

  def secrets_file(cfg, name), do: Path.join([cfg.apps_dir, name, "secrets.env"])

  defp ensure_secrets!(cfg, name, wanted) do
    path = secrets_file(cfg, name)

    have =
      if File.exists?(path) do
        for line <- String.split(File.read!(path), "\n", trim: true),
            [k, v] <- [String.split(line, "=", parts: 2)],
            into: %{},
            do: {k, v}
      else
        %{}
      end

    all = Enum.reduce(wanted, have, fn k, acc -> Map.put_new_lazy(acc, k, fn -> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false) end) end)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(all, "", fn {k, v} -> "#{k}=#{v}\n" end))
    File.chmod!(path, 0o600)
    path
  end

  def run(cfg, job, tag, plan, log) do
    name = job["name"]
    c = container(name)
    secrets = ensure_secrets!(cfg, name, plan["secrets"])
    if plan["secrets"] != [], do: log.("secrets #{Enum.join(plan["secrets"], ", ")}: in #{secrets} (not logged)")

    _ = Shell.run("docker", ["rm", "-f", c], [], log)

    labels = %{
      "obs_factor.id" => name,
      "obs_factor.label" => job["label"] || name,
      "obs_factor.kind" => "app",
      "obs_factor.hosts" => job["fqdn"],
      "obs_factor.probe" => "http://#{c}:#{plan["port"]}#{plan["health"]}",
      "obs_factor.platform" => "built",
      "obs_factor.build" => job["id"],
      "obs_factor.repo" => "#{job["repo"]}@#{String.slice(job["commit"] || "", 0, 12)}"
    }

    args =
      ["run", "-d", "--name", c, "--network", cfg.network, "--restart", "unless-stopped", "--memory", "#{plan["memory_mb"]}m", "--env-file", secrets] ++
        Enum.flat_map(labels, fn {k, v} -> ["--label", "#{k}=#{v}"] end) ++
        Enum.flat_map(plan["env"], fn {k, v} -> ["-e", "#{k}=#{v}"] end) ++
        Enum.flat_map(plan["volumes"], fn v -> ["-v", "#{c}-#{v["name"]}:#{v["path"]}"] end) ++
        [tag]

    with {:ok, _} <- Shell.run("docker", args, [timeout: 60_000], log) |> err("docker run"),
         :ok <- settle(c, log, 8) do
      {:ok, "#{c}:#{plan["port"]}"}
    end
  end

  defp err({:ok, v}, _), do: {:ok, v}
  defp err({:error, msg, tail}, what), do: {:error, "#{what}: #{msg}: #{tail |> Enum.take(-2) |> Enum.join(" | ")}"}

  # A container that exits or restarts in its first seconds is a failed
  # service, and its last log lines say why.
  defp settle(c, log, seconds) do
    Process.sleep(seconds * 1000)

    case Shell.run("docker", ["inspect", "-f", "{{.State.Status}} {{.RestartCount}}", c], [], fn _ -> :ok end) do
      {:ok, [line | _]} ->
        case String.split(line) do
          ["running", "0"] ->
            log.("#{c}: running")
            :ok

          other ->
            log.("#{c}: #{Enum.join(other, " restarts=")}; last lines:")
            _ = Shell.run("docker", ["logs", "--tail", "25", c], [], log)
            {:error, "#{c} is not staying up (#{Enum.join(other, ", restarts ")})"}
        end

      {:error, msg, _} ->
        {:error, "docker inspect #{c}: #{msg}"}
    end
  end
end
