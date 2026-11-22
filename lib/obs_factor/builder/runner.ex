defmodule ObsFactor.Builder.Runner do
  @moduledoc """
  Runs one job's steps in order; the first failure stops it. Each step is one
  primitive:

      name     A record <name>.<domain> -> the box, checked against the DNS server
      route    a Caddy site for it: the lot (a placeholder page), checked through Caddy
      source   git clone of the repository
      recipe   the agent reads the README and writes .obs_factor/build.json
      image    docker build
      service  docker run, labelled for the observer
      check    the route becomes a reverse_proxy; the health path answers through Caddy

  A route-only job is `name, route, check`: a reserved lot.
  """

  alias ObsFactor.Builder.{Jobs, Name, Recipe, Route, Service, Source}

  def run(job) do
    cfg = Jobs.config()
    id = job["id"]

    result =
      Enum.reduce_while(job["steps"], %{job: job}, fn %{"name" => step}, acc ->
        Jobs.step(id, step, "running")
        log = fn line -> Jobs.log(id, step, line) end

        case step(step, cfg, acc, log) do
          {:ok, note, acc} ->
            Jobs.step(id, step, "done", note)
            {:cont, acc}

          {:error, why} ->
            log.("FAILED: " <> why)
            Jobs.step(id, step, "failed", why)
            {:halt, {:error, why}}
        end
      end)

    case result do
      {:error, why} ->
        undo_name(cfg, job)
        Jobs.finish(id, "failed", why)

      _ ->
        Jobs.finish(id, "live")
    end
  end

  # If the job never got a route, its A record points at a host with no
  # site for it: take the record back out. Once the route exists the lot
  # stays, failed builds included, so the hostname says what happened.
  defp undo_name(cfg, job) do
    {:ok, j} = Jobs.get(job["id"])
    route = Enum.find(j["steps"], &(&1["name"] == "route"))

    if route["state"] != "done" do
      Name.delete(cfg, job["name"])
      Jobs.log(job["id"], "name", "removed the A record for #{job["fqdn"]}: the job has no route")
    end
  end

  defp step("name", cfg, acc, log) do
    with {:ok, note} <- Name.put(cfg, acc.job["name"], acc.job["id"], log), do: {:ok, note, acc}
  end

  defp step("route", cfg, %{job: j} = acc, log) do
    text =
      if j["mode"] == "route",
        do: "#{j["fqdn"]}: this lot is reserved. Nothing is built here yet.",
        else: "#{j["fqdn"]} is under construction: obs_factor is building #{j["repo"]}."

    with :ok <- Route.put(cfg, j["name"], Route.placeholder(cfg, j["name"], j["fqdn"], j["id"], text), log),
         {:ok, s} <- Route.wait_answer(cfg, j["fqdn"], "/", true, 20, log) do
      {:ok, "placeholder answers #{s} through Caddy", acc}
    end
  end

  defp step("source", cfg, %{job: j} = acc, log) do
    with {:ok, sha} <- Source.clone(cfg, j["name"], j["repo"], j["ref"], log) do
      Jobs.put(j["id"], %{"commit" => sha})
      {:ok, "#{String.slice(sha, 0, 12)}", %{acc | job: Map.put(j, "commit", sha)} |> Map.put(:dir, Source.dir(cfg, j["name"]))}
    end
  end

  defp step("recipe", cfg, %{job: j, dir: dir} = acc, log) do
    with {:ok, plan} <- Recipe.run(cfg, dir, j["fqdn"], log) do
      summary = %{"summary" => plan["summary"], "notes" => plan["notes"], "port" => plan["port"], "health" => plan["health"], "secrets" => plan["secrets"], "dockerfile" => plan["dockerfile"]}
      Jobs.put(j["id"], %{"plan" => plan, "plan_summary" => summary})
      written = agent_files(dir)
      if written != [], do: log.("files the agent wrote: #{Enum.join(written, ", ")}")
      {:ok, "port #{plan["port"]}, health #{plan["health"]}, #{plan["dockerfile"]}", Map.put(acc, :plan, plan)}
    end
  end

  defp step("image", cfg, %{job: j, dir: dir, plan: plan} = acc, log) do
    with {:ok, tag} <- Service.build(cfg, j["name"], j["commit"], dir, plan, log), do: {:ok, tag, Map.put(acc, :image, tag)}
  end

  defp step("service", cfg, %{job: j, image: tag, plan: plan} = acc, log) do
    with {:ok, upstream} <- Service.run(cfg, j, tag, plan, log), do: {:ok, upstream, Map.put(acc, :upstream, upstream)}
  end

  defp step("check", cfg, %{job: %{"mode" => "route"} = j} = acc, log) do
    with [_ | _] <- Name.lookup(cfg, j["fqdn"]),
         {:ok, s} <- Route.wait_answer(cfg, j["fqdn"], "/", true, 10, log) do
      log.("lot reserved")
      {:ok, "#{j["fqdn"]} resolves and the lot answers #{s}", acc}
    else
      [] -> {:error, "#{j["fqdn"]} stopped resolving"}
      {:error, _} = e -> e
    end
  end

  defp step("check", cfg, %{job: j, upstream: up, plan: plan} = acc, log) do
    with :ok <- Route.put(cfg, j["name"], Route.proxy(cfg, j["name"], j["fqdn"], j["id"], up), log),
         {:ok, s} <- Route.wait_answer(cfg, j["fqdn"], plan["health"], false, 120, log) do
      {:ok, "#{plan["health"]} answers #{s} through Caddy", acc}
    end
  end

  defp agent_files(dir) do
    case System.cmd("git", ["-C", dir, "status", "--porcelain", "--untracked-files=all"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.slice(&1, 3..-1//1))
      _ -> []
    end
  end
end
