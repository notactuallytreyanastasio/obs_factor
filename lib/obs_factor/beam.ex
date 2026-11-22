defmodule ObsFactor.Beam do
  @moduledoc """
  The observer looking at itself: the Erlang VM it runs on, the processes
  under `ObsFactor.Supervisor` (one collector per source among them), the
  ETS tables the snapshot is built from, and its own recent log
  (`ObsFactor.LogRing`). Served at `GET /api/beam` for the "Under the hood"
  panel.

  Everything is read at request time with `Process.info/2`, `:erlang.memory/0`
  and `:ets.info/2`. Nothing calls into a collector (`:sys.get_state` would
  wait behind a poll in progress), so a stuck collector shows as stuck here
  instead of hanging the page.
  """

  @proc_keys [:registered_name, :status, :message_queue_len, :memory, :reductions, :current_function, :links]

  def report(opts \\ []) do
    %{
      at: DateTime.utc_now(),
      vm: vm(),
      processes: processes(),
      tables: tables(),
      log: ObsFactor.LogRing.recent(Keyword.get(opts, :log_limit, 200), Keyword.get(opts, :log_level, :debug)),
      log_kept: ObsFactor.LogRing.keep()
    }
  end

  defp vm do
    {wall_ms, _} = :erlang.statistics(:wall_clock)
    mem = Map.new(:erlang.memory())

    %{
      node: node(),
      otp: to_string(:erlang.system_info(:otp_release)),
      erts: to_string(:erlang.system_info(:version)),
      elixir: System.version(),
      uptime_s: div(wall_ms, 1000),
      schedulers: :erlang.system_info(:schedulers_online),
      run_queue: :erlang.statistics(:total_run_queue_lengths_all),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      atom_count: :erlang.system_info(:atom_count),
      ets_count: length(:ets.all()),
      memory: Map.take(mem, [:total, :processes, :ets, :binary, :code, :atom, :system])
    }
  end

  # The top of the tree: what ObsFactor.Supervisor runs. A collector's id is
  # its source module, so its row carries the source's last result too.
  defp processes do
    case Process.whereis(ObsFactor.Supervisor) do
      nil ->
        []

      _ ->
        for {id, pid, type, _} <- Supervisor.which_children(ObsFactor.Supervisor) do
          base = %{id: label(id), type: type, pid: pid_text(pid), alive: is_pid(pid) and Process.alive?(pid)}

          base
          |> Map.merge(info(pid))
          |> Map.merge(children(type, pid))
          |> Map.merge(source(id))
        end
    end
  end

  defp label(id) when is_atom(id), do: id |> inspect() |> String.replace_prefix("ObsFactor.", "")
  defp label(id), do: inspect(id)

  defp info(pid) when is_pid(pid) do
    case Process.info(pid, @proc_keys) do
      nil ->
        %{}

      i ->
        %{
          registered_name: if(i[:registered_name] in [nil, []], do: nil, else: inspect(i[:registered_name])),
          status: i[:status],
          message_queue_len: i[:message_queue_len],
          memory_bytes: i[:memory],
          reductions: i[:reductions],
          current_function: mfa(i[:current_function]),
          links: length(i[:links] || [])
        }
    end
  end

  defp info(_), do: %{}

  defp children(:supervisor, pid) when is_pid(pid) do
    c = Supervisor.count_children(pid)
    %{children: c[:active]}
  catch
    _, _ -> %{}
  end

  defp children(_, _), do: %{}

  # ObsFactor.Collector children are {Collector, {Module, opts}} with the
  # source module as id (Collector.child_spec/1).
  defp source(id) when is_atom(id) do
    with true <- Code.ensure_loaded?(id) and function_exported?(id, :collect, 1),
         name = id.name(),
         true <- :ets.whereis(ObsFactor.Sources) != :undefined,
         [{_, e}] <- :ets.lookup(ObsFactor.Sources, name) do
      now = System.system_time(:millisecond)
      %{source: %{name: name, ok: e.ok, error: e.error, last_ok_at: e.at, attempted_ms_ago: now - e.attempted_at, max_age_ms: e.max_age_ms}}
    else
      _ -> %{}
    end
  end

  defp source(_), do: %{}

  defp tables do
    word = :erlang.system_info(:wordsize)

    for t <- [ObsFactor.Sources, ObsFactor.Store, ObsFactor.LogRing, ObsFactor.History], :ets.whereis(t) != :undefined do
      %{name: label(t), size: :ets.info(t, :size), memory_bytes: :ets.info(t, :memory) * word, owner: t |> :ets.info(:owner) |> pid_text(), type: :ets.info(t, :type)}
    end
  end

  defp mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp mfa(_), do: nil

  defp pid_text(p) when is_pid(p), do: p |> :erlang.pid_to_list() |> to_string()
  defp pid_text(other), do: inspect(other)
end
