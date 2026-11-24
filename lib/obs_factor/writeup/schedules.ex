defmodule ObsFactor.Writeup.Schedules do
  @moduledoc """
  Writeups that write themselves: daily or weekly, at an hour (UTC), with
  any of the Write up panel's options (apps, a wire filter, sections).

  Each run writes up the period that just ended (the 24 h, or the 7 days,
  up to the scheduled instant), saves it as a shared writeup
  (`ObsFactor.Writeup.save/4`, by "schedule: <name>"), and, when the
  schedule has a webhook, POSTs `{"text", "title", "url"}` to it: Slack's
  incoming webhooks read `text`, anything else can read the rest.

  `ObsFactor.Writeup.Scheduler` looks every minute for schedules due: the
  latest scheduled instant at or before now, if it is after both the last
  run and the schedule's creation (so a schedule made at 10:00 for 09:00
  first runs tomorrow, not at once). A missed instant (the observer was
  down) runs when it comes back, once.
  """

  alias ObsFactor.{Tape, Writeup}

  @ddl """
  CREATE TABLE IF NOT EXISTS writeup_schedules (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    every text NOT NULL CHECK (every IN ('daily', 'weekly')),
    hour integer NOT NULL CHECK (hour BETWEEN 0 AND 23),
    weekday integer CHECK (weekday BETWEEN 1 AND 7),
    options jsonb NOT NULL,
    webhook text,
    by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_run_at timestamptz,
    last_slug text,
    last_error text
  )
  """

  @cols "id, name, every, hour, weekday, options, webhook, by, created_at, last_run_at, last_slug, last_error"

  def list(db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT #{@cols} FROM writeup_schedules ORDER BY name, id", []) do
      now = System.system_time(:millisecond)
      {:ok, Enum.map(rows, &(&1 |> row() |> with_next(now)))}
    end
  end

  @doc "Save a schedule: `%{\"name\", \"every\", \"hour\", \"weekday\", \"options\", \"webhook\", \"by\"}`, `\"id\"` to change one."
  def save(a, db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, name} <- req_text(a["name"], "a schedule needs a name"),
         {:ok, every} <- one_of(a["every"], ~w(daily weekly), "every is daily or weekly"),
         {:ok, hour} <- int_in(a["hour"], 0..23, "hour is 0 to 23 (UTC)"),
         {:ok, weekday} <- weekday(every, a["weekday"]),
         {:ok, webhook} <- webhook(a["webhook"]),
         {:ok, options} <- options(a["options"]) do
      by = if is_binary(a["by"]), do: String.slice(a["by"], 0, 60)
      params = [name, every, hour, weekday, options, webhook]

      result =
        case a["id"] do
          nil -> q(db, "INSERT INTO writeup_schedules (name, every, hour, weekday, options, webhook, by) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING #{@cols}", params ++ [by])
          id when is_integer(id) -> q(db, "UPDATE writeup_schedules SET name = $2, every = $3, hour = $4, weekday = $5, options = $6, webhook = $7 WHERE id = $1 RETURNING #{@cols}", [id | params])
          other -> {:error, "a schedule id is an integer, got #{inspect(other)}"}
        end

      case result do
        {:ok, %{rows: [r]}} -> {:ok, r |> row() |> with_next(System.system_time(:millisecond))}
        {:ok, %{rows: []}} -> {:error, "no schedule #{a["id"]}"}
        {:error, e} -> {:error, Tape.message(e)}
      end
    end
  end

  def delete(id, db \\ Tape.db())

  def delete(id, db) when is_integer(id) do
    with :ok <- ensure(db),
         {:ok, %{num_rows: 1}} <- q(db, "DELETE FROM writeup_schedules WHERE id = $1", [id]) do
      {:ok, id}
    else
      {:ok, %{num_rows: 0}} -> {:error, "no schedule #{id}"}
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  def delete(id, _), do: {:error, "a schedule id is an integer, got #{inspect(id)}"}

  # ---- when ---------------------------------------------------------------------

  @day 86_400_000

  @doc "The latest scheduled instant at or before `now_ms` (unix ms)."
  def last_instant(%{every: "daily", hour: h}, now_ms) do
    today = div(now_ms, @day) * @day + h * 3_600_000
    if today <= now_ms, do: today, else: today - @day
  end

  def last_instant(%{every: "weekly", hour: h, weekday: wd}, now_ms) do
    d = last_instant(%{every: "daily", hour: h}, now_ms)
    # 1970-01-01 was a Thursday (ISO weekday 4)
    dow = rem(div(d, @day) + 3, 7) + 1
    d - rem(dow - wd + 7, 7) * @day
  end

  def next_instant(%{every: every} = s, now_ms), do: last_instant(s, now_ms) + if(every == "daily", do: @day, else: 7 * @day)

  @doc "Is a run due at `now_ms`? Then `{:due, instant}`, else `:no`."
  def due(s, now_ms) do
    i = last_instant(s, now_ms)
    floor = max(s.created_at || 0, s.last_run_at || 0)
    if i > floor, do: {:due, i}, else: :no
  end

  @doc "The period a run at `instant` writes up."
  def period(%{every: "daily"}, instant), do: {instant - @day, instant}
  def period(%{every: "weekly"}, instant), do: {instant - 7 * @day, instant}

  # ---- a run ----------------------------------------------------------------------

  @doc """
  Write up the period ending at `instant`, save it, post it to the webhook,
  and record the run. `{:ok, saved}` or `{:error, reason}` (also recorded).
  `post` sends the webhook (Req by default; tests pass their own).
  """
  def run(s, instant, opts \\ []) do
    db = Keyword.get(opts, :db, Tape.db())
    post = Keyword.get(opts, :post, &post/2)
    base = Keyword.get(opts, :base_url, ObsFactorWeb.Endpoint.url())
    {from, to} = period(s, instant)
    title = "#{s.name}: #{Calendar.strftime(DateTime.from_unix!(to, :millisecond), "%Y-%m-%d %H:%M")} UTC"

    built =
      with {:ok, w} <- Writeup.build(atomize(s.options) ++ [from: from, to: to, title: title, base_url: base, db: db]),
           {:ok, saved} <- Writeup.save(w, Map.merge(s.options, %{"schedule" => s.id, "from" => from, "to" => to}), "schedule: #{s.name}", db) do
        url = "#{base}/w/#{saved.slug}.md"
        hook = if s.webhook, do: post.(s.webhook, %{text: "#{title}\n#{url}", title: title, url: url}), else: :ok
        {:ok, Map.put(saved, :url, url), hook}
      end

    case built do
      {:ok, saved, hook} ->
        err = case hook do :ok -> nil; {:error, e} -> "written, but the webhook failed: #{e}" end
        record(db, s.id, instant, saved.slug, err)
        if err, do: {:error, err}, else: {:ok, saved}

      {:error, e} ->
        record(db, s.id, instant, nil, Tape.message(e))
        {:error, Tape.message(e)}
    end
  end

  defp record(db, id, instant, slug, err) do
    q(db, "UPDATE writeup_schedules SET last_run_at = $2, last_slug = coalesce($3, last_slug), last_error = $4 WHERE id = $1",
      [id, DateTime.from_unix!(instant, :millisecond), slug, err])
  end

  @doc false
  def post(url, body) do
    case Req.post(url, json: body, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s}} -> {:error, "answered #{s}"}
      {:error, e} -> {:error, Exception.message(e)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---- the rows -------------------------------------------------------------------

  defp row([id, name, every, hour, wd, options, webhook, by, created, last, slug, err]) do
    %{id: id, name: name, every: every, hour: hour, weekday: wd, options: options, webhook: webhook, by: by,
      created_at: ms(created), last_run_at: ms(last), last_slug: slug, last_error: err}
  end

  defp with_next(s, now), do: Map.put(s, :next_at, next_due(s, now))

  # the next instant a run will happen: now if one is due, else the next one
  defp next_due(s, now) do
    case due(s, now) do
      {:due, _} -> now
      :no -> next_instant(s, now)
    end
  end

  defp atomize(o) do
    [apps: o["apps"], sections: o["sections"], spec: o["spec"]] ++ if(is_integer(o["set"]), do: [set: o["set"]], else: [])
    |> Enum.reject(fn {_, v} -> v in [nil, []] end)
    |> then(fn kw -> if kw[:set], do: Keyword.put_new(kw, :spec, set_spec(kw[:set])) |> Keyword.delete(:set), else: kw end)
  end

  defp set_spec(id) do
    case ObsFactor.WireFilters.list() do
      {:ok, sets} -> Enum.find_value(sets, &(&1.id == id && &1.spec))
      _ -> nil
    end
  end

  defp options(nil), do: {:ok, %{}}

  defp options(o) when is_map(o) do
    apps = Enum.filter(List.wrap(o["apps"]), &is_binary/1)
    sections = Enum.filter(List.wrap(o["sections"]), &(&1 in Writeup.sections()))
    set = if is_integer(o["set"]), do: o["set"]
    {:ok, %{"apps" => apps, "sections" => sections, "set" => set} |> Map.reject(fn {_, v} -> v in [nil, []] end)}
  end

  defp options(_), do: {:error, "options is a map of apps, sections and set"}

  defp weekday("daily", _), do: {:ok, nil}
  defp weekday("weekly", w), do: int_in(w, 1..7, "a weekly schedule needs a weekday, 1 (Monday) to 7 (Sunday)")

  defp webhook(w) when w in [nil, ""], do: {:ok, nil}

  defp webhook(w) when is_binary(w) do
    case URI.parse(String.trim(w)) do
      %URI{scheme: s, host: h} when s in ["https", "http"] and is_binary(h) and h != "" -> {:ok, String.trim(w)}
      _ -> {:error, "a webhook is an http(s) URL"}
    end
  end

  defp webhook(_), do: {:error, "a webhook is an http(s) URL"}

  defp req_text(t, msg) when is_binary(t) do
    case String.trim(t) do
      "" -> {:error, msg}
      v -> {:ok, String.slice(v, 0, 80)}
    end
  end

  defp req_text(_, msg), do: {:error, msg}

  defp one_of(v, list, msg), do: if(v in list, do: {:ok, v}, else: {:error, msg})

  defp int_in(v, range, msg) when is_integer(v), do: if(v in range, do: {:ok, v}, else: {:error, msg})
  defp int_in(_, _, msg), do: {:error, msg}

  defp ensure(db) do
    case q(db, @ddl, []) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)
end
