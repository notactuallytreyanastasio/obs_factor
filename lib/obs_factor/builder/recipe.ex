defmodule ObsFactor.Builder.Recipe do
  @moduledoc """
  Primitive 4, the recipe: an agent reads the repository (README first) and
  writes `.obs_factor/build.json`, which says how to run it here: Dockerfile,
  port, health path, env, secrets, volumes, memory. If the repository has no
  usable Dockerfile the agent writes one. The builder, not the agent, builds
  and runs it.

  The agent is `ObsFactor.Builder.Agent` over a chat completions API
  (BUILDER_LLM_URL / _KEY / _MODEL; DeepSeek in the lab) with four tools,
  all confined to the clone: `list_files`, `read_file`, `grep` and
  `write_file`, which only writes under `.obs_factor/`. No shell, no
  network, no symlinks followed (a repository can ship a symlink to
  /etc/passwd). The repository's text still reaches the model, so a README
  can steer what it writes: that is why the plan is validated here, never
  trusted as is.
  """

  alias ObsFactor.Builder.Agent

  @plan_path ".obs_factor/build.json"
  @env_name ~r/^[A-Z_][A-Z0-9_]{0,63}$/
  @vol_name ~r/^[a-z0-9][a-z0-9-]{0,30}$/
  @skip ~w(.git target node_modules _build deps dist build .next vendor)
  # About 3k tokens. A result stays in the conversation until compacted, so
  # every byte returned is paid again on each later turn: the model pages
  # through big files instead.
  @max_read 12_000

  def prompt(fqdn) do
    """
    You are preparing this GitHub repository to run as one container on a small Docker host, behind Caddy, at http://#{fqdn}/. Use the tools to read the repository: README.md first, then whatever else you need (Dockerfile, build files, config, the code that starts the server). Paths are relative to the repository root.

    Write the file #{@plan_path} with write_file. If the repository has no Dockerfile that builds a runnable server, also write one as .obs_factor/Dockerfile (its build context is the repository root). You can only write under .obs_factor/, and you cannot run commands.

    #{@plan_path} is one JSON object with exactly these keys:
      "dockerfile": path of the Dockerfile, relative to the repository root
      "context": the build context directory, relative to the repository root (usually ".")
      "port": the TCP port the server listens on inside the container. It must listen on 0.0.0.0, not 127.0.0.1: set whatever env var does that.
      "health": an HTTP path that answers with a status below 500 once the server is up (an auth-protected path answering 401 is fine)
      "env": object of plain environment variables the server needs (never secrets)
      "secrets": array of environment variable names that must hold a secret (tokens, passwords). The platform generates a random value for each and keeps it out of logs.
      "volumes": array of {"name": "<lowercase-name>", "path": "/absolute/path/in/container"} for data that must survive a restart
      "memory_mb": memory limit in MB, 64 to 4096
      "summary": one or two sentences: what this server is and how it is configured
      "notes": what a human should know before relying on it (assumptions you made, what you could not tell)

    If the repository has several programs, pick the long-running network server that makes sense at #{fqdn}. If there is no such server, still write #{@plan_path}, with "port": null, and say why in "notes".

    Work economically. Every tool result stays in the conversation and is paid for again on every later turn, so: call several tools in the same turn whenever they do not depend on each other; use grep to find the lines you need rather than reading whole files; read files in ranges; stop reading as soon as you have the evidence for every key. Old tool results may be replaced by a short note to save space; call the tool again if you need one.

    Check your claims against the code, not only the README: the port, the bind address and the health path must be ones the server really uses. When you are done, reply with one short paragraph saying what you chose and why, without calling a tool.
    """
  end

  def run(cfg, dir, fqdn, log) do
    File.rm(Path.join(dir, @plan_path))
    llm = cfg.llm
    log.("agent: #{llm.model} at #{llm.url}")
    started = System.monotonic_time(:millisecond)

    system =
      "You are a careful build engineer. You inspect repositories with the tools you are given and write exactly the files you are asked for. You never invent facts about a repository: you read them."

    case Agent.run(llm, system, prompt(fqdn), tools(dir), log, max_turns: 24, compact_at: 24_000, keep_turns: 2) do
      {:ok, text, usage} ->
        if text != "", do: log.("agent: " <> text)
        secs = div(System.monotonic_time(:millisecond) - started, 1000)
        log.("agent finished: #{secs} s, #{length(usage.turns)} turns, #{Enum.sum(Enum.map(usage.turns, & &1.calls))} tool calls, #{usage.compactions} compactions, " <>
               "#{usage.prompt} prompt tokens (#{usage.cached} from cache) + #{usage.completion} completion")
        log.("agent prompt per turn (k tokens, cached): " <> Enum.map_join(usage.turns, " ", fn t -> "#{Float.round(t.prompt / 1000, 1)}(#{Float.round(t.cached / 1000, 1)})" end))
        read_plan(dir, log)

      {:error, msg} ->
        {:error, "agent: #{msg}"}
    end
  end

  ## Tools

  @doc "The recipe agent's tools, confined to `dir`."
  def tools(dir) do
    [
      %{
        name: "list_files",
        description: "List files under a directory of the repository, recursively (skips .git, target, node_modules and other build output). At most 300 entries.",
        parameters: %{type: "object", properties: %{path: %{type: "string", description: "directory relative to the repository root; default \".\""}}},
        run: fn args -> list_files(dir, args["path"] || ".") end
      },
      %{
        name: "read_file",
        description: "Read part of a text file of the repository, as numbered lines (150 by default, at most 400, at most 12000 characters). Page with offset for more; grep first to find where to look.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string"},
            offset: %{type: "integer", description: "first line, 1-based; default 1"},
            limit: %{type: "integer", description: "number of lines; default 150, at most 400"}
          },
          required: ["path"]
        },
        run: fn args -> read_file(dir, args["path"], args["offset"] || 1, args["limit"] || 150) end
      },
      %{
        name: "grep",
        description: "Search the repository's text files for a regular expression (PCRE). Returns up to 40 matches as path:line: text. The cheapest way to find something.",
        parameters: %{
          type: "object",
          properties: %{pattern: %{type: "string"}, path: %{type: "string", description: "directory or file to search; default \".\""}},
          required: ["pattern"]
        },
        run: fn args -> grep(dir, args["pattern"], args["path"] || ".") end
      },
      %{
        name: "write_file",
        description: "Write a file. Only paths under .obs_factor/ are allowed. Overwrites.",
        parameters: %{type: "object", properties: %{path: %{type: "string"}, content: %{type: "string"}}, required: ["path", "content"]},
        run: fn args -> write_file(dir, args["path"], args["content"]) end
      }
    ]
  end

  # Resolves `rel` inside `dir`, refusing anything outside it and any path
  # with a symlink in it.
  def resolve(dir, rel) when is_binary(rel) do
    full = Path.expand(rel, dir)

    cond do
      full != dir and not String.starts_with?(full, dir <> "/") ->
        {:error, "#{rel} is outside the repository"}

      symlink_on_path?(dir, full) ->
        {:error, "#{rel} goes through a symlink, which is not followed"}

      true ->
        {:ok, full}
    end
  end

  def resolve(_, rel), do: {:error, "path #{inspect(rel)} is not a string"}

  defp symlink_on_path?(dir, full) do
    full
    |> Path.relative_to(dir)
    |> Path.split()
    |> Enum.scan(dir, &Path.join(&2, &1))
    |> Enum.any?(&match?({:ok, %File.Stat{type: :symlink}}, File.lstat(&1)))
  end

  defp list_files(dir, rel) do
    with {:ok, root} <- resolve(dir, rel),
         true <- File.dir?(root) || {:error, "#{rel} is not a directory"} do
      files = walk(root) |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.sort()
      more = if length(files) > 300, do: "\n... #{length(files) - 300} more: list a subdirectory", else: ""
      {:ok, Enum.join(Enum.take(files, 300), "\n") <> more}
    end
  end

  defp walk(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if Path.basename(path) in @skip, do: [], else: path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1)))

      {:ok, %File.Stat{type: :regular}} ->
        [path]

      _ ->
        []
    end
  end

  defp read_file(dir, rel, offset, limit) do
    with {:ok, full} <- resolve(dir, rel),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(full) |> or_error("#{rel} does not exist"),
         true <- size <= 5_000_000 || {:error, "#{rel} is #{size} bytes, too big to read"},
         {:ok, raw} <- File.read(full),
         true <- String.valid?(raw) || {:error, "#{rel} is not UTF-8 text"} do
      lines = String.split(raw, "\n")
      offset = max(1, offset)
      chunk = lines |> Enum.drop(offset - 1) |> Enum.take(max(1, min(limit, 400)))
      body = chunk |> Enum.with_index(offset) |> Enum.map_join("\n", fn {l, i} -> "#{i}\t#{l}" end)
      shown = offset + length(chunk) - 1
      tail = if shown < length(lines), do: "\n[lines #{offset}-#{shown} of #{length(lines)}]", else: ""
      cut = if byte_size(body) > @max_read, do: "\n[cut at #{@max_read} characters: read fewer lines]", else: ""
      {:ok, binary_part(body, 0, min(byte_size(body), @max_read)) |> String.replace_invalid() |> Kernel.<>(cut <> tail)}
    else
      {:ok, %File.Stat{}} -> {:error, "#{rel} is not a regular file"}
      {:error, _} = e -> e
    end
  end

  defp grep(dir, pattern, rel) do
    with {:ok, re} <- Regex.compile(pattern) |> or_error("bad regex #{inspect(pattern)}"),
         {:ok, root} <- resolve(dir, rel),
         true <- File.exists?(root) || {:error, "#{rel} does not exist"} do
      files = if File.dir?(root), do: walk(root), else: [root]

      hits =
        files
        |> Stream.filter(&(File.stat!(&1).size < 1_000_000))
        |> Stream.flat_map(fn f ->
          raw = File.read!(f)

          if String.valid?(raw) do
            raw
            |> String.split("\n")
            |> Stream.with_index(1)
            |> Stream.filter(fn {l, _} -> Regex.match?(re, l) end)
            |> Stream.map(fn {l, i} -> "#{Path.relative_to(f, dir)}:#{i}: #{String.slice(l, 0, 200)}" end)
          else
            []
          end
        end)
        |> Enum.take(41)

      more = if length(hits) > 40, do: "\n... more matches: narrow the pattern or the path", else: ""
      {:ok, if(hits == [], do: "no matches", else: Enum.join(Enum.take(hits, 40), "\n") <> more)}
    end
  end

  defp write_file(dir, rel, content) do
    with {:ok, full} <- resolve(dir, rel),
         true <- String.starts_with?(full, Path.join(dir, ".obs_factor") <> "/") || {:error, "only paths under .obs_factor/ can be written"},
         true <- (is_binary(content) and byte_size(content) <= 200_000) || {:error, "content must be a string of at most 200 kB"} do
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      {:ok, "wrote #{rel} (#{byte_size(content)} bytes)"}
    end
  end

  defp read_plan(dir, log) do
    path = Path.join(dir, @plan_path)

    with {:ok, raw} <- File.read(path) |> or_error("the agent did not write #{@plan_path}"),
         {:ok, plan} <- Jason.decode(raw) |> or_error("#{@plan_path} is not JSON"),
         {:ok, plan} <- validate(plan, dir) do
      log.("plan: #{Jason.encode!(Map.drop(plan, ["summary", "notes"]))}")
      {:ok, plan}
    end
  end

  defp or_error({:ok, v}, _), do: {:ok, v}
  defp or_error(_, msg), do: {:error, msg}

  @doc "Checks the agent's plan. Returns `{:ok, plan}` with defaults filled, or `{:error, why}`."
  def validate(%{} = p, dir) do
    env = p["env"] || %{}
    secrets = p["secrets"] || []
    volumes = p["volumes"] || []
    mem = p["memory_mb"] || 512

    cond do
      p["port"] == nil ->
        {:error, "the agent found nothing to run: #{p["notes"] || "no notes"}"}

      not (is_integer(p["port"]) and p["port"] in 1..65535) ->
        {:error, "port #{inspect(p["port"])} is not a port number"}

      not inside?(dir, p["dockerfile"]) or not File.regular?(Path.join(dir, p["dockerfile"])) ->
        {:error, "dockerfile #{inspect(p["dockerfile"])} is not a file in the repository"}

      not inside?(dir, p["context"] || ".") ->
        {:error, "context #{inspect(p["context"])} is not inside the repository"}

      not (is_binary(p["health"]) and String.starts_with?(p["health"], "/") and not String.contains?(p["health"], [" ", "\n"])) ->
        {:error, "health #{inspect(p["health"])} is not a path"}

      not (is_map(env) and Enum.all?(env, fn {k, v} -> Regex.match?(@env_name, k) and is_binary(v) end)) ->
        {:error, "env must map NAME to a string"}

      not (is_list(secrets) and Enum.all?(secrets, &(is_binary(&1) and Regex.match?(@env_name, &1)))) ->
        {:error, "secrets must be a list of env var names"}

      not Enum.all?(volumes, &(is_map(&1) and is_binary(&1["name"]) and Regex.match?(@vol_name, &1["name"]) and is_binary(&1["path"]) and String.starts_with?(&1["path"], "/"))) ->
        {:error, "volumes must be [{name, path}] with lowercase names and absolute paths"}

      not (is_integer(mem) and mem in 64..4096) ->
        {:error, "memory_mb #{inspect(mem)} is not 64..4096"}

      true ->
        {:ok,
         %{
           "dockerfile" => p["dockerfile"],
           "context" => p["context"] || ".",
           "port" => p["port"],
           "health" => p["health"],
           "env" => env,
           "secrets" => secrets,
           "volumes" => volumes,
           "memory_mb" => mem,
           "summary" => to_string(p["summary"] || ""),
           "notes" => to_string(p["notes"] || "")
         }}
    end
  end

  def validate(_, _), do: {:error, "#{@plan_path} is not a JSON object"}

  defp inside?(dir, rel) when is_binary(rel) do
    full = Path.expand(rel, dir)
    full == dir or String.starts_with?(full, dir <> "/")
  end

  defp inside?(_, _), do: false
end
