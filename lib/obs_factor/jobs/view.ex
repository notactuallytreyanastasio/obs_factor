defmodule ObsFactor.Jobs.View do
  @moduledoc """
  What the board's Oban tab shows, read from `oban_jobs` (`ObsFactor.Repo`)
  and from Oban itself. Times are unix milliseconds, durations milliseconds.

  `view/1`:

    * `queues`: per configured queue, `limit`, `paused`, `executing` (what
      the producer runs now, `Oban.check_queue/1`) and the jobs `available`,
      `scheduled`, `retryable` in it
    * `states`: per state, jobs in it now (the incomplete ones) or finished
      into it in the last 24 h (`completed`, `discarded`, `cancelled`)
    * `minutes`: the last 60 minutes, `[t, completed, failed, errors]`, where
      `failed` is discarded and cancelled and `errors` is attempts that
      raised or returned an error (a retried job counts once per attempt)
    * `workers`: per worker, the last 24 h: `completed`, `discarded`,
      `cancelled`, `retried` (attempted more than once), `pending`, run time
      `p50`/`p95` (attempted to completed), `wait_p95` (scheduled to
      attempted; a job waiting for its retry has its next attempt as
      `scheduled_at`, so it is left out), and its latest job `last: %{id, state, at}`
    * `cron`: `ObsFactor.Jobs.crontab/0`, each with `next_at` and its
      worker's `last`
    * `jobs`: the newest 60 matching `filter` (`state`, `queue`, `worker`),
      each `id, worker, queue, state, attempt, max_attempts, inserted_at,
      scheduled_at, attempted_at, finished_at, args` (cut to 160 characters)
      and `error` (the last one's first line)

  `job/1`: one job whole, with its `errors` (attempt, at, error) and `meta`.

  Everything is a few aggregate queries over a table the Pruner keeps to 7
  days, which on this box is about 12,000 rows (1,440 ticks and 288 rollups
  a day, plus writeups and webhooks).
  """

  alias ObsFactor.{Jobs, Repo}

  @incomplete ~w(available scheduled executing retryable)
  @states ~w(available scheduled executing retryable completed discarded cancelled)
  @jobs_limit 60

  def states, do: @states

  defp ms(col), do: "(extract(epoch from #{col}) * 1000)::bigint"

  @doc "The whole tab. `{:ok, view}` or `{:error, reason}`."
  def view(filter \\ %{}) do
    with {:ok, counts} <- counts(),
         {:ok, minutes} <- minutes(),
         {:ok, workers} <- workers(),
         {:ok, jobs} <- jobs(filter) do
      by_queue = Enum.group_by(counts, & &1.queue)
      last = Map.new(workers, &{&1.worker, &1.last})

      {:ok,
       %{
         now: System.system_time(:millisecond),
         queues: queues(by_queue),
         states:
           Enum.reduce(counts, Map.new(@states, &{&1, 0}), fn c, acc ->
             Map.update(acc, c.state, c.n, &(&1 + c.n))
           end),
         minutes: minutes,
         workers: workers,
         cron: cron(last),
         jobs: jobs,
         filter: clean(filter)
       }}
    end
  end

  # ---- the parts ---------------------------------------------------------------

  defp counts do
    sql = """
    SELECT queue, state::text, count(*) FROM oban_jobs
    WHERE state::text = ANY($1)
       OR coalesce(completed_at, discarded_at, cancelled_at) > timezone('UTC', now()) - interval '24 hours'
    GROUP BY 1, 2
    """

    with {:ok, rows} <- q(sql, [@incomplete]),
         do: {:ok, for([qu, s, n] <- rows, do: %{queue: qu, state: s, n: n})}
  end

  defp queues(by_queue) do
    names = Enum.map(Jobs.queues(), fn {q, _} -> to_string(q) end)
    others = Map.keys(by_queue) -- names

    for name <- names ++ Enum.sort(others) do
      n = Map.new(Map.get(by_queue, name, []), &{&1.state, &1.n})
      live = check(name)

      %{
        name: name,
        limit: live[:limit],
        paused: live[:paused],
        running: length(live[:running] || []),
        configured: name in names,
        executing: Map.get(n, "executing", 0),
        available: Map.get(n, "available", 0),
        scheduled: Map.get(n, "scheduled", 0),
        retryable: Map.get(n, "retryable", 0),
        completed: Map.get(n, "completed", 0),
        discarded: Map.get(n, "discarded", 0)
      }
    end
  end

  defp check(name) do
    if Jobs.enabled?() do
      case Oban.check_queue(queue: name) do
        %{} = m -> m
        _ -> %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp minutes do
    since = "date_trunc('minute', timezone('UTC', now())) - interval '59 minutes'"

    sql = """
    SELECT 'c', #{ms("date_trunc('minute', completed_at)")}, count(*) FROM oban_jobs WHERE completed_at >= #{since} GROUP BY 2
    UNION ALL
    SELECT 'f', #{ms("date_trunc('minute', coalesce(discarded_at, cancelled_at))")}, count(*) FROM oban_jobs
      WHERE coalesce(discarded_at, cancelled_at) >= #{since} GROUP BY 2
    UNION ALL
    SELECT 'e', #{ms("date_trunc('minute', (e->>'at')::timestamptz AT TIME ZONE 'UTC')")}, count(*)
      FROM oban_jobs, unnest(errors) e
      WHERE cardinality(errors) > 0 AND attempted_at >= #{since} - interval '1 hour'
        AND (e->>'at')::timestamptz AT TIME ZONE 'UTC' >= #{since}
      GROUP BY 2
    """

    with {:ok, rows} <- q(sql, []) do
      now = System.system_time(:millisecond)
      start = div(now, 60_000) * 60_000 - 59 * 60_000
      got = Map.new(rows, fn [k, t, n] -> {{k, t}, n} end)

      {:ok,
       for(
         i <- 0..59,
         t = start + i * 60_000,
         do: [t, got[{"c", t}] || 0, got[{"f", t}] || 0, got[{"e", t}] || 0]
       )}
    end
  end

  defp workers do
    sql = """
    WITH w AS (
      SELECT * FROM oban_jobs
      WHERE state::text = ANY($1) OR inserted_at > timezone('UTC', now()) - interval '24 hours'
    ), last AS (
      SELECT DISTINCT ON (worker) worker, id, state::text AS state,
             #{ms("coalesce(completed_at, discarded_at, cancelled_at, attempted_at, scheduled_at)")} AS at
      FROM oban_jobs ORDER BY worker, id DESC
    )
    SELECT w.worker, min(w.queue),
      count(*) FILTER (WHERE w.state = 'completed'),
      count(*) FILTER (WHERE w.state = 'discarded'),
      count(*) FILTER (WHERE w.state = 'cancelled'),
      count(*) FILTER (WHERE w.attempt > 1),
      count(*) FILTER (WHERE w.state::text = ANY($1)),
      percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from w.completed_at - w.attempted_at) * 1000) FILTER (WHERE w.state = 'completed'),
      percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch from w.completed_at - w.attempted_at) * 1000) FILTER (WHERE w.state = 'completed'),
      percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch from w.attempted_at - w.scheduled_at) * 1000) FILTER (WHERE w.attempted_at >= w.scheduled_at),
      min(l.id), min(l.state), min(l.at)
    FROM w LEFT JOIN last l ON l.worker = w.worker
    GROUP BY w.worker ORDER BY w.worker
    """

    with {:ok, rows} <- q(sql, [@incomplete]) do
      {:ok,
       for [w, qu, c, d, x, r, p, p50, p95, wait, lid, ls, lat] <- rows do
         %{
           worker: w,
           queue: qu,
           completed: c,
           discarded: d,
           cancelled: x,
           retried: r,
           pending: p,
           p50: round_ms(p50),
           p95: round_ms(p95),
           wait_p95: round_ms(wait),
           last: lid && %{id: lid, state: ls, at: lat}
         }
       end}
    end
  end

  defp cron(last) do
    now = DateTime.utc_now()

    for {expr, worker} <- Jobs.crontab() do
      name = worker |> to_string() |> String.replace_prefix("Elixir.", "")

      next =
        case Oban.Cron.Expression.parse(expr) do
          {:ok, e} ->
            case Oban.Cron.Expression.next_at(e, now) do
              %DateTime{} = d -> DateTime.to_unix(d, :millisecond)
              _ -> nil
            end

          _ ->
            nil
        end

      %{expr: expr, worker: name, next_at: next, last: last[name]}
    end
  end

  @doc "The newest jobs matching a filter (`state`, `queue`, `worker`)."
  def jobs(filter \\ %{}) do
    f = clean(filter)

    sql = """
    SELECT id, worker, queue, state::text, attempt, max_attempts,
      #{ms("inserted_at")}, #{ms("scheduled_at")}, #{ms("attempted_at")},
      #{ms("coalesce(completed_at, discarded_at, cancelled_at)")},
      left(args::text, 160),
      split_part(errors[cardinality(errors)]->>'error', E'\\n', 1)
    FROM oban_jobs
    WHERE ($1::text IS NULL OR state::text = $1) AND ($2::text IS NULL OR queue = $2) AND ($3::text IS NULL OR worker = $3)
    ORDER BY id DESC LIMIT #{@jobs_limit}
    """

    with {:ok, rows} <- q(sql, [f["state"], f["queue"], f["worker"]]) do
      {:ok,
       for [id, w, qu, s, a, m, ins, sch, att, fin, args, err] <- rows do
         %{
           id: id,
           worker: w,
           queue: qu,
           state: s,
           attempt: a,
           max_attempts: m,
           inserted_at: ins,
           scheduled_at: sch,
           attempted_at: att,
           finished_at: fin,
           args: args,
           error: blank(err)
         }
       end}
    end
  end

  @doc "One job, whole: `{:ok, job}` or `{:error, \"no job <id>\"}`."
  def job(id) when is_integer(id) do
    sql = """
    SELECT id, worker, queue, state::text, attempt, max_attempts, priority, args, meta, tags, attempted_by,
      #{ms("inserted_at")}, #{ms("scheduled_at")}, #{ms("attempted_at")}, #{ms("completed_at")},
      #{ms("discarded_at")}, #{ms("cancelled_at")},
      (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM unnest(errors) e)
    FROM oban_jobs WHERE id = $1
    """

    case q(sql, [id]) do
      {:ok,
       [[id, w, qu, s, a, m, pr, args, meta, tags, by, ins, sch, att, comp, disc, canc, errors]]} ->
        {:ok,
         %{
           id: id,
           worker: w,
           queue: qu,
           state: s,
           attempt: a,
           max_attempts: m,
           priority: pr,
           args: args,
           meta: meta,
           tags: tags,
           attempted_by: by,
           inserted_at: ins,
           scheduled_at: sch,
           attempted_at: att,
           completed_at: comp,
           discarded_at: disc,
           cancelled_at: canc,
           errors: Enum.map(errors, &%{attempt: &1["attempt"], at: &1["at"], error: &1["error"]})
         }}

      {:ok, []} ->
        {:error, "no job #{id}"}

      {:error, e} ->
        {:error, e}
    end
  end

  def job(id), do: {:error, "a job id is an integer, got #{inspect(id)}"}

  # ---- small things --------------------------------------------------------------

  @doc false
  def clean(filter) when is_map(filter) do
    %{
      "state" => (filter["state"] in @states && filter["state"]) || nil,
      "queue" => text(filter["queue"]),
      "worker" => text(filter["worker"])
    }
  end

  def clean(_), do: clean(%{})

  defp text(v) when is_binary(v) and v != "", do: String.slice(v, 0, 120)
  defp text(_), do: nil

  defp blank(""), do: nil
  defp blank(v), do: v

  defp round_ms(nil), do: nil
  defp round_ms(v) when is_float(v), do: Float.round(v, 1)
  defp round_ms(v), do: v

  defp q(sql, params) do
    if Process.whereis(Repo) do
      case Repo.query(sql, params) do
        {:ok, %{rows: rows}} -> {:ok, rows}
        {:error, e} -> {:error, ObsFactor.Tape.message(e)}
      end
    else
      {:error, "no jobs: OBJECTIVES_PG_URL is not set"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, why -> {:error, "jobs: #{inspect(why)}"}
  end
end
