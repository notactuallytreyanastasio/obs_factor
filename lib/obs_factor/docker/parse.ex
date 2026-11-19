defmodule ObsFactor.Docker.Parse do
  @moduledoc """
  Parsers for the three Docker Engine API payloads the observer reads.

  The inspect body (`/containers/{id}/json`) carries every secret the container
  was started with in `Config.Env`. `inspect/1` takes the *raw binary*, keeps a
  handful of fields and returns nothing else; if anything about the body is
  unexpected it returns an error that names the field, never the body. No
  exception carrying the decoded term can escape from here, because crash
  reports would print it.
  """

  @doc "One container from `/containers/json?all=1`."
  def list_entry(%{"Id" => id, "Names" => [name | _], "State" => state} = c) do
    labels = Map.get(c, "Labels") || %{}

    %{
      id: id,
      name: String.trim_leading(name, "/"),
      image: c["Image"],
      state: state,
      status_text: c["Status"],
      service: labels["com.docker.compose.service"],
      project: labels["com.docker.compose.project"],
      oneoff: labels["com.docker.compose.oneoff"] == "True"
    }
  end

  def list_entry(other) do
    raise ArgumentError,
          "container list entry without Id/Names/State: keys #{inspect(Map.keys(other))}"
  end

  @doc """
  Parses a raw inspect body into the fields we use. Returns `{:ok, map}` or
  `{:error, message}`; the message never contains body content.
  """
  def inspect_body(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> inspect_fields(decoded)
      {:error, _} -> {:error, "inspect body is not JSON"}
    end
  rescue
    e -> {:error, "inspect body could not be parsed (#{inspect(e.__struct__)})"}
  end

  defp inspect_fields(%{"State" => state, "HostConfig" => host_config} = body)
       when is_map(state) and is_map(host_config) do
    with {:ok, status} <- field(state, "Status", &is_binary/1),
         {:ok, running} <- field(state, "Running", &is_boolean/1),
         {:ok, restarting} <- field(state, "Restarting", &is_boolean/1),
         {:ok, oom} <- field(state, "OOMKilled", &is_boolean/1),
         {:ok, exit_code} <- field(state, "ExitCode", &is_integer/1),
         {:ok, started_at} <- field(state, "StartedAt", &is_binary/1),
         {:ok, finished_at} <- field(state, "FinishedAt", &is_binary/1),
         {:ok, restarts} <- field(body, "RestartCount", &is_integer/1),
         {:ok, memory} <- field(host_config, "Memory", &is_integer/1) do
      health =
        case state["Health"] do
          %{"Status" => s} when is_binary(s) -> s
          _ -> nil
        end

      policy =
        case host_config["RestartPolicy"] do
          %{"Name" => n} when is_binary(n) -> n
          _ -> nil
        end

      {:ok,
       %{
         status: status,
         running: running,
         restarting: restarting,
         oom_killed: oom,
         exit_code: exit_code,
         started_at: timestamp(started_at),
         finished_at: timestamp(finished_at),
         health: health,
         restart_count: restarts,
         restart_policy: policy,
         memory_limit: if(memory > 0, do: memory, else: nil)
       }}
    end
  end

  defp inspect_fields(_), do: {:error, "inspect body has no State/HostConfig objects"}

  defp field(map, key, ok?) do
    value = Map.get(map, key)
    if ok?.(value), do: {:ok, value}, else: {:error, "inspect field #{key} missing or mistyped"}
  end

  # Docker writes "0001-01-01T00:00:00Z" for never.
  defp timestamp("0001-01-01T00:00:00Z"), do: nil

  defp timestamp(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc """
  The cumulative counters from one `/containers/{id}/stats?stream=false&one-shot=true`
  body. With one-shot the `precpu_stats` are zero, so rates come from our own
  successive samples (see `ObsFactor.Docker.rates/3`).

  Memory is what `docker stats` shows: usage minus the inactive file cache.
  Under cgroup v2 (the box) the field is `inactive_file`; under v1 it is
  `total_inactive_file`.
  """
  def stats(%{"read" => read, "cpu_stats" => cpu, "memory_stats" => mem} = body) do
    {:ok, read_at, _} = DateTime.from_iso8601(read)

    total = get_in(cpu, ["cpu_usage", "total_usage"])
    system = cpu["system_cpu_usage"]
    online = cpu["online_cpus"]

    unless is_integer(total) and is_integer(system) and is_integer(online) do
      raise ArgumentError,
            "stats for #{body["name"]}: cpu_stats lacks total_usage/system_cpu_usage/online_cpus " <>
              "(keys #{inspect(Map.keys(cpu))})"
    end

    usage = mem["usage"]
    inner = mem["stats"] || %{}

    cache =
      cond do
        is_integer(inner["inactive_file"]) -> inner["inactive_file"]
        is_integer(inner["total_inactive_file"]) -> inner["total_inactive_file"]
        true -> raise ArgumentError, "stats for #{body["name"]}: no inactive_file in memory_stats"
      end

    unless is_integer(usage) do
      raise ArgumentError, "stats for #{body["name"]}: memory_stats has no usage"
    end

    {rx, tx} =
      case body["networks"] do
        nets when is_map(nets) and map_size(nets) > 0 ->
          Enum.reduce(nets, {0, 0}, fn {_, n}, {rx, tx} ->
            {rx + n["rx_bytes"], tx + n["tx_bytes"]}
          end)

        # network_mode: host or none: Docker reports no per-container counters.
        _ ->
          {nil, nil}
      end

    %{
      read_at: read_at,
      cpu_total_ns: total,
      system_ns: system,
      online_cpus: online,
      mem_bytes: max(usage - cache, 0),
      rx_bytes: rx,
      tx_bytes: tx
    }
  end

  def stats(other) do
    raise ArgumentError,
          "stats body without read/cpu_stats/memory_stats: keys #{inspect(Map.keys(other))}"
  end
end
