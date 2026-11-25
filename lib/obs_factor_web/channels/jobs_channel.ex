defmodule ObsFactorWeb.JobsChannel do
  @moduledoc """
  `jobs`: the board's Oban tab (`ObsFactor.Jobs`, `ObsFactor.Jobs.View`).

  The join reply is the view (`ObsFactor.Jobs.View.view/1`, the jobs list
  filtered by the join's `filter`, `%{state, queue, worker}`), or
  `%{error: reason}` when there is no Oban (OBJECTIVES_PG_URL unset) or
  Postgres does not answer; the join succeeds either way. Then a `view`
  push whenever it changes (`ObsFactor.Jobs.Live`, at most every 1.5 s, at
  least every 10 s), with this socket's filter applied.

  Reads, replied `{:ok, ...}` or `{:error, %{error}}`:

    * `filter` `%{state, queue, worker}`: the jobs list for it, kept for
      the pushes after
    * `job` `%{id}`: one job whole (`%{job}`), args, meta and every error

  Writes, an operator's (`ObsFactorWeb.Identity`), replied `{:ok, %{ok:
  what}}` or `{:error, %{error}}`:

    * `retry` `%{id}`, `cancel` `%{id}`, `delete` `%{id}`
    * `pause` `%{queue}`, `resume` `%{queue}`
    * `run_cron` `%{worker}`: a job of a crontab worker, now
  """
  use ObsFactorWeb, :channel

  alias ObsFactor.Jobs
  alias ObsFactor.Jobs.{Live, View}

  @impl true
  def join("jobs", params, socket) do
    filter = View.clean(params["filter"] || %{})
    socket = assign(socket, :filter, filter)
    {:ok, reply(View.view(filter)), socket}
  end

  defp reply({:ok, v}), do: v

  defp reply({:error, e}),
    do: %{error: e, queues: [], states: %{}, minutes: [], workers: [], cron: [], jobs: []}

  @impl true
  def handle_info({:jobs_view, v}, socket) do
    f = socket.assigns.filter

    v =
      if f == View.clean(%{}),
        do: v,
        else:
          (case View.jobs(f) do
             {:ok, jobs} -> %{v | jobs: jobs, filter: f}
             _ -> v
           end)

    push(socket, "view", v)
    {:noreply, socket}
  end

  def handle_info({:jobs_error, e}, socket) do
    push(socket, "view", reply({:error, e}))
    {:noreply, socket}
  end

  @impl true
  def handle_in("filter", params, socket) when is_map(params) do
    f = View.clean(params)

    case View.jobs(f) do
      {:ok, jobs} -> {:reply, {:ok, %{jobs: jobs, filter: f}}, assign(socket, :filter, f)}
      {:error, e} -> {:reply, {:error, %{error: e}}, socket}
    end
  end

  def handle_in("job", %{"id" => id}, socket) do
    case View.job(id) do
      {:ok, j} -> {:reply, {:ok, %{job: j}}, socket}
      {:error, e} -> {:reply, {:error, %{error: e}}, socket}
    end
  end

  def handle_in("retry", %{"id" => id}, socket) when is_integer(id),
    do:
      {:reply, operator(socket, "retry_job", fn -> Oban.retry_job(id) end, "retried #{id}"),
       socket}

  def handle_in("cancel", %{"id" => id}, socket) when is_integer(id),
    do:
      {:reply, operator(socket, "cancel_job", fn -> Oban.cancel_job(id) end, "cancelled #{id}"),
       socket}

  def handle_in("delete", %{"id" => id}, socket) when is_integer(id),
    do:
      {:reply, operator(socket, "delete_job", fn -> Oban.delete_job(id) end, "deleted #{id}"),
       socket}

  def handle_in("pause", %{"queue" => q}, socket) when is_binary(q),
    do:
      {:reply,
       operator(socket, "pause_queue", fn -> queue(q, &Oban.pause_queue/1) end, "paused #{q}"),
       socket}

  def handle_in("resume", %{"queue" => q}, socket) when is_binary(q),
    do:
      {:reply,
       operator(socket, "resume_queue", fn -> queue(q, &Oban.resume_queue/1) end, "resumed #{q}"),
       socket}

  def handle_in("run_cron", %{"worker" => w}, socket) when is_binary(w),
    do: {:reply, operator(socket, "run_cron", fn -> run_cron(w) end, "enqueued #{w}"), socket}

  def handle_in(event, params, socket),
    do:
      {:reply, {:error, %{error: "jobs: cannot #{inspect(event)} with #{inspect(params)}"}},
       socket}

  # ---- writes ---------------------------------------------------------------------

  defp queue(q, fun) do
    if q in Enum.map(Jobs.queues(), fn {n, _} -> to_string(n) end),
      do: fun.(queue: q),
      else: {:error, "no queue #{inspect(q)} here"}
  end

  # only a worker on the crontab, never a module named by the page
  defp run_cron(w) do
    case Enum.find(Jobs.crontab(), fn {_, mod} -> inspect(mod) == w end) do
      {_, mod} -> Oban.insert(mod.new(%{}, meta: %{"by_hand" => true}))
      nil -> {:error, "#{w} is not on the crontab"}
    end
  end

  defp operator(socket, action, fun, ok) do
    with :ok <- ObsFactorWeb.Identity.authorize(socket.assigns[:identity], action, []),
         true <- Jobs.enabled?() || {:error, "no jobs: OBJECTIVES_PG_URL is not set"} do
      case fun.() do
        {:error, e} ->
          {:error, %{error: ObsFactor.Tape.message(e)}}

        _ ->
          Live.touch()
          {:ok, %{ok: ok}}
      end
    else
      {:error, why} -> {:error, %{error: why}}
    end
  rescue
    e -> {:error, %{error: Exception.message(e)}}
  end
end
