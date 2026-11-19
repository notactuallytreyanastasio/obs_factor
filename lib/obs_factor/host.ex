defmodule ObsFactor.Host do
  @moduledoc """
  Host collector: `HOST_PROC/{stat,meminfo,loadavg}` and statfs on
  `HOST_DISK_PATH`.

  statfs: the release image is Debian slim, which always has GNU coreutils
  (an Essential package), so we run `stat -f -c '%S %b %f %a' PATH`. That is
  statfs(2) itself - fundamental block size, total, free and available blocks,
  the same four numbers as `statvfs` - with no shell, no NIF and no extra
  package. `df` was the alternative but its output is meant for people;
  `:disksup` polls every 30 minutes and reports only a rounded percentage.

  CPU needs two /proc/stat readings; the first tick reports cpu as nil.
  """

  @behaviour ObsFactor.Collector

  @impl true
  def name, do: :host

  @impl true
  def init_state(opts) do
    %{proc: Keyword.get(opts, :proc), disk: Keyword.get(opts, :disk), prev_cpu: nil}
  end

  @impl true
  def collect(%{proc: nil} = state), do: {:error, "HOST_PROC is not set", state}
  def collect(%{disk: nil} = state), do: {:error, "HOST_DISK_PATH is not set", state}

  def collect(state) do
    with {:ok, stat} <- read(state.proc, "stat"),
         {:ok, meminfo} <- read(state.proc, "meminfo"),
         {:ok, loadavg} <- read(state.proc, "loadavg"),
         {:ok, disk} <- statfs(state.disk) do
      cpu = parse_stat(stat)

      data =
        %{
          cores: cpu.cores,
          cpu_used_cores: cpu_used(state.prev_cpu, cpu),
          load1: parse_loadavg(loadavg)
        }
        |> Map.merge(parse_meminfo(meminfo))
        |> Map.merge(disk_usage(disk))

      {:ok, data, %{state | prev_cpu: cpu}}
    else
      {:error, message} -> {:error, message, state}
    end
  end

  defp read(dir, file) do
    path = Path.join(dir, file)

    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Runs statfs on `path` through coreutils `stat -f`."
  def statfs(path) do
    case System.find_executable("stat") do
      nil ->
        {:error, "no stat executable for statfs"}

      exe ->
        case System.cmd(exe, ["-f", "-c", "%S %b %f %a", path], stderr_to_stdout: true) do
          {out, 0} ->
            case out |> String.trim() |> String.split(" ") |> Enum.map(&Integer.parse/1) do
              [{frsize, ""}, {blocks, ""}, {bfree, ""}, {bavail, ""}] ->
                {:ok, %{f_frsize: frsize, f_blocks: blocks, f_bfree: bfree, f_bavail: bavail}}

              _ ->
                {:error, "statfs: unexpected stat output #{inspect(String.slice(out, 0, 120))}"}
            end

          {out, code} ->
            {:error, "statfs: stat -f exited #{code}: #{String.slice(String.trim(out), 0, 160)}"}
        end
    end
  end

  @doc "First `cpu` line of /proc/stat plus the number of `cpuN` lines."
  def parse_stat(text) do
    lines = String.split(text, "\n")

    fields =
      case Enum.find(lines, &String.starts_with?(&1, "cpu ")) do
        nil -> raise ArgumentError, "/proc/stat has no aggregate cpu line"
        l -> l |> String.split() |> tl() |> Enum.map(&String.to_integer/1)
      end

    # user nice system idle iowait irq softirq steal (guest is inside user)
    [user, nice, system, idle, iowait, irq, softirq, steal | _] = fields ++ List.duplicate(0, 8)
    idle_all = idle + iowait
    busy = user + nice + system + irq + softirq + steal

    %{
      cores: Enum.count(lines, &Regex.match?(~r/^cpu\d+ /, &1)),
      busy: busy,
      total: busy + idle_all
    }
  end

  def cpu_used(nil, _cur), do: nil

  def cpu_used(prev, cur) do
    d_total = cur.total - prev.total
    d_busy = cur.busy - prev.busy
    if d_total > 0 and d_busy >= 0, do: d_busy / d_total * cur.cores, else: nil
  end

  @doc "Used = MemTotal - MemAvailable, in bytes."
  def parse_meminfo(text) do
    kv =
      for line <- String.split(text, "\n"),
          [k, v] <- [String.split(line, ":", parts: 2)],
          into: %{} do
        {k, v |> String.trim() |> String.split() |> hd() |> String.to_integer()}
      end

    total = kv["MemTotal"] || raise ArgumentError, "meminfo has no MemTotal"
    avail = kv["MemAvailable"] || raise ArgumentError, "meminfo has no MemAvailable"
    %{mem_total_bytes: total * 1024, mem_used_bytes: (total - avail) * 1024}
  end

  def parse_loadavg(text) do
    {load1, _} = text |> String.split() |> hd() |> Float.parse()
    load1
  end

  @doc """
  Disk usage the way `df` counts it: used = blocks - free; the percentage
  that fills up is used / (used + available), because blocks reserved for
  root are not available to anyone else.
  """
  def disk_usage(%{f_frsize: bs, f_blocks: blocks, f_bfree: bfree, f_bavail: bavail}) do
    %{
      disk_total_bytes: blocks * bs,
      disk_used_bytes: (blocks - bfree) * bs,
      disk_avail_bytes: bavail * bs
    }
  end
end
