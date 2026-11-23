defmodule ObsFactor.Insights do
  @moduledoc """
  What went wrong in a window of time, and how it was handled: the Fires
  panel. Two sources, read together:

    * the objectives (`ObsFactor.Objectives`): when each fire started, who
      looked, who put it out or whether it burned out by itself, and how
      often it came back;
    * the tape (`ObsFactor.Tape`): how long each building actually burned,
      frame by frame, the share of the window with no alert, and the worst
      moments by 5xx and by alerts.

  The objectives say what people did; the tape says what the floor did. A
  fire nobody looked at that cleared itself is in both, and that difference
  ("burned out, nobody came") is the point of the panel.

  All durations are milliseconds, all times unix milliseconds.
  """

  alias ObsFactor.Tape

  @doc "`{:ok, insights}` or `{:error, reason}` for `[from, to]`."
  def compute(from_ms, to_ms, db \\ Tape.db()) do
    with {:ok, objs} <- objectives(from_ms, to_ms, db),
         {:ok, burn} <- Tape.burn(from_ms, to_ms, db),
         {:ok, weather} <- Tape.weather(from_ms, to_ms, db) do
      {:ok, build(objs, burn, weather, from_ms, to_ms)}
    end
  end

  @doc false
  def build(objs, burn, weather, from_ms, to_ms) do
    in_window = fn t -> t != nil and t >= from_ms and t <= to_ms end
    started = Enum.filter(objs, &in_window.(&1.opened_at))
    put_out = Enum.filter(objs, &(&1.state == "done" and in_window.(&1.done_at)))
    burned_out = Enum.filter(objs, &(&1.cleared_at != nil and in_window.(&1.cleared_at)))

    %{
      from: from_ms,
      to: to_ms,
      score: %{
        # alive at the window's end: opened by then, not yet closed by then
        burning: Enum.count(objs, &(&1.opened_at <= to_ms and (closed_at(&1) == nil or closed_at(&1) > to_ms))),
        started: length(started) + Enum.sum(Enum.map(objs, & &1.returns)),
        put_out: length(put_out),
        burned_out: length(burned_out),
        # cleared by itself and nobody ever said they were looking
        unattended: Enum.count(burned_out, &(&1.looked_at == nil)),
        respond_ms: median(for(o <- objs, o.looked_at && in_window.(o.looked_at), do: o.looked_at - o.opened_at)),
        put_out_ms: median(for(o <- put_out, do: o.done_at - o.opened_at)),
        longest: longest(objs, to_ms)
      },
      calm: %{
        share: if(weather.tape_ms > 0, do: Float.round(weather.calm_ms / weather.tape_ms, 3)),
        tape_ms: weather.tape_ms,
        frames: weather.frames,
        last_alert: weather.last_alert
      },
      hot: hot(burn, objs),
      repeat:
        objs
        |> Enum.filter(&(&1.returns > 0 or &1.seen_count > 2))
        |> Enum.sort_by(&{-&1.returns, -&1.seen_count})
        |> Enum.take(5)
        |> Enum.map(&Map.take(&1, [:id, :node, :title, :severity, :returns, :seen_count, :state])),
      peaks: weather.peaks,
      worst: weather.worst
    }
  end

  # Per building: time burning (alerts, then warnings) on the tape, how many
  # fires the objectives opened on it, and the last thing said. Worst first.
  defp hot(burn, objs) do
    starts = Enum.frequencies_by(objs, & &1.node)

    burn
    |> Enum.group_by(& &1.node)
    |> Enum.map(fn {node, rows} ->
      by = Map.new(rows, &{&1.severity, &1})
      latest = Enum.max_by(rows, & &1.last)

      %{
        node: node,
        alert_ms: (by["alert"] && by["alert"].ms) || 0,
        warn_ms: (by["warn"] && by["warn"].ms) || 0,
        fires: Map.get(starts, node, 0),
        last: latest.last,
        text: latest.text
      }
    end)
    |> Enum.sort_by(&{-&1.alert_ms, -&1.warn_ms})
    |> Enum.take(8)
  end

  defp longest([], _), do: nil

  defp longest(objs, to_ms) do
    o = Enum.max_by(objs, &burned(&1, to_ms))
    %{id: o.id, node: o.node, title: o.title, ms: burned(o, to_ms), state: o.state}
  end

  defp burned(o, to_ms), do: (closed_at(o) || to_ms) - o.opened_at

  defp closed_at(o), do: o.done_at || o.cleared_at

  defp median([]), do: nil

  defp median(xs) do
    s = Enum.sort(xs)
    Enum.at(s, div(length(s), 2))
  end

  # Every objective alive at some point in the window, with when it was
  # first looked at and how often it came back inside the window.
  defp objectives(from_ms, to_ms, db) do
    sql = """
    SELECT o.id, o.node, o.severity, o.title, o.state, o.seen_count,
           o.opened_at, o.cleared_at, o.done_at,
           (SELECT min(e.at) FROM objective_events e WHERE e.objective_id = o.id AND e.kind = 'looking'),
           (SELECT count(*) FROM objective_events e
             WHERE e.objective_id = o.id AND e.kind = 'came back' AND e.at >= $1 AND e.at <= $2)
    FROM objectives o
    WHERE o.opened_at <= $2 AND coalesce(o.done_at, o.cleared_at, now()) >= $1
    """

    case Postgrex.query(db, sql, [dt(from_ms), dt(to_ms)]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         for [id, node, sev, title, state, seen, opened, cleared, done, looked, returns] <- rows do
           %{
             id: id,
             node: node,
             severity: sev,
             title: title,
             state: state,
             seen_count: seen,
             opened_at: ms(opened),
             cleared_at: ms(cleared),
             done_at: ms(done),
             looked_at: ms(looked),
             returns: returns
           }
         end}

      {:error, e} ->
        {:error, Tape.message(e)}
    end
  catch
    :exit, reason -> {:error, Tape.message(reason)}
  end

  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)
end
