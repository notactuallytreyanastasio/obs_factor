defmodule ObsFactor.Builder.Shell do
  @moduledoc """
  Runs one program (never a shell string: arguments are a list) and hands
  every output line to a callback as it arrives, so a 10-minute
  `docker build` shows progress instead of silence. stderr is merged into
  stdout. On timeout the OS process is killed, not just disowned.
  """

  @doc """
  `run(program, args, opts, on_line)`. Options: `:cd`, `:env` (list of
  `{name, value | nil}`; nil unsets), `:timeout` (ms, default 60_000).
  Returns `{:ok, output_tail}` on exit 0, `{:error, message, output_tail}`
  otherwise. `output_tail` is the last 40 lines.
  """
  def run(program, args, opts \\ [], on_line \\ fn _ -> :ok end) do
    exe =
      System.find_executable(program) ||
        throw({:missing, program})

    # open_port unsets a variable given `false` (not nil).
    env = for {k, v} <- Keyword.get(opts, :env, []), do: {to_charlist(k), if(v, do: to_charlist(v), else: false)}

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:line, 8192}, {:args, args}, {:env, env}] ++
        if(opts[:cd], do: [{:cd, opts[:cd]}], else: [])

    port = Port.open({:spawn_executable, exe}, port_opts)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 60_000)
    loop(port, deadline, on_line, [], "", program)
  catch
    {:missing, p} -> {:error, "#{p}: not found on PATH", []}
  end

  defp loop(port, deadline, on_line, tail, partial, program) do
    left = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = partial <> chunk
        on_line.(line)
        loop(port, deadline, on_line, keep(tail, line), "", program)

      {^port, {:data, {:noeol, chunk}}} ->
        loop(port, deadline, on_line, tail, partial <> chunk, program)

      {^port, {:exit_status, code}} ->
        tail =
          if partial != "" do
            on_line.(partial)
            keep(tail, partial)
          else
            tail
          end

        lines = Enum.reverse(tail)
        if code == 0, do: {:ok, lines}, else: {:error, "#{program} exited #{code}", lines}
    after
      left ->
        kill(port)
        {:error, "#{program} timed out", Enum.reverse(tail)}
    end
  end

  defp keep(tail, line), do: Enum.take([line | tail], 40)

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)])
      nil -> :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end
end
