defmodule ObsFactor.Collector do
  @moduledoc """
  One supervised process per source. On every tick it runs the source's
  `collect/1` in an unlinked task with a deadline shorter than the interval, so
  a hung source reports a timeout instead of piling up, and writes the result
  into `ObsFactor.Sources`.

  Only transitions (ok -> error, error -> ok, a changed error) are logged.
  """

  use GenServer
  require Logger

  @callback name() :: atom
  @callback init_state(opts :: keyword) :: term
  @callback collect(state :: term) ::
              {:ok, data :: term, state :: term} | {:error, String.t(), state :: term}

  def child_spec({module, opts}) do
    %{id: module, start: {__MODULE__, :start_link, [module, opts]}}
  end

  def start_link(module, opts) do
    GenServer.start_link(__MODULE__, {module, opts}, name: module)
  end

  @impl true
  def init({module, opts}) do
    interval = Keyword.fetch!(opts, :interval_ms)
    # Leave room for the task to be killed and the result written before the next tick.
    deadline = Keyword.get(opts, :deadline_ms, max(interval - 750, 500))

    state = %{
      module: module,
      interval: interval,
      deadline: deadline,
      inner: module.init_state(opts),
      last_error: :none
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    started = System.system_time(:millisecond)
    module = state.module
    inner = state.inner

    task =
      Task.Supervisor.async_nolink(ObsFactor.TaskSupervisor, fn ->
        try do
          module.collect(inner)
        rescue
          e -> {:error, short(Exception.message(e)), inner}
        catch
          kind, reason -> {:error, short("#{kind}: #{inspect(reason, limit: 5)}"), inner}
        end
      end)

    {result, inner} =
      case Task.yield(task, state.deadline) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, data, inner}} -> {{:ok, data}, inner}
        {:ok, {:error, message, inner}} -> {{:error, message}, inner}
        {:exit, reason} -> {{:error, short("crashed: #{inspect(reason, limit: 5)}")}, inner}
        nil -> {{:error, "timed out after #{state.deadline} ms"}, inner}
      end

    name = module.name()
    previous = :ets.lookup(ObsFactor.Sources, name)
    last_ok_at = with [{_, %{at: at}}] <- previous, do: at, else: (_ -> nil)
    max_age = state.interval * 3

    entry =
      case result do
        {:ok, data} ->
          %{
            ok: true,
            at: DateTime.from_unix!(started, :millisecond),
            error: nil,
            data: data,
            attempted_at: started,
            max_age_ms: max_age
          }

        {:error, message} ->
          %{
            ok: false,
            at: last_ok_at,
            error: message,
            data: nil,
            attempted_at: started,
            max_age_ms: max_age
          }
      end

    ObsFactor.Sources.put(name, entry)

    {:noreply,
     %{state | inner: inner, last_error: log_transition(name, state.last_error, entry.error, System.system_time(:millisecond) - started)}}
  end

  # Late replies from a task that was already given up on.
  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  # `previous` is :none before the first result, nil after an ok one, else
  # the error. source.ok is the first ok since boot, source.recovered an ok
  # after an error; source.failed is a new error or a different one.
  defp log_transition(_name, same, same, _took), do: same

  defp log_transition(name, previous, nil, took) do
    if is_binary(previous) do
      Logger.info("source #{name}: ok again", event: "source.recovered", source: name, previous_error: previous, took_ms: took)
    else
      Logger.info("source #{name}: ok", event: "source.ok", source: name, took_ms: took)
    end

    nil
  end

  defp log_transition(name, previous, error, took) do
    meta = [event: "source.failed", source: name, reason: error, took_ms: took]
    meta = if is_binary(previous), do: meta ++ [previous_error: previous], else: meta
    Logger.warning("source #{name}: #{error}", meta)
    error
  end

  @doc "Trims an error message to something that fits in the snapshot."
  def short(message) when is_binary(message) do
    if String.length(message) > 300, do: String.slice(message, 0, 297) <> "...", else: message
  end
end
