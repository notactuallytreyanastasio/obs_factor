defmodule ObsFactor.Reports do
  @moduledoc """
  Reports collector: what a sub-app says about its own inside (see "Reports"
  in docs/contract.md). Every tick, each topology node's `report` URL is read
  (GET, 2 s timeout, concurrently, `authorization: Bearer <REPORT_TOKEN>` when
  the token is set), the document is validated, and the cumulative counters
  are turned into rates between two reads of the same process.

  The source is ok when the round ran. A node whose report cannot be read, is
  not JSON, has the wrong shape or an unknown `factory_report` version fails
  alone: `%{ok: false, error, at}` with `at` the last good read.

  A report is external input. It is validated here, at the boundary, and what
  leaves this module is bounded whatever the reporter sent: at most
  100 units, 20 members per unit, 300 streams (the busiest by `count`), 100
  keys per gauge/counter/version map, 50 events, strings cut at 120
  characters (an event's message at 300). What is cut here is added to the reporter's own `truncated`.
  A gauge or counter whose value is not a number is ignored.

  A stream row is one `kind` + `name` + `by`: a breakdown row (`by` says
  whose process caused it) and its total (no `by`) are different rows, each
  with its own rates.

  A restart resets every counter. Every rate of a read is `nil` (no negative,
  no spike) when, against the previous good read:

    * `uptime_s` is smaller, or
    * any counter or stream total went backwards, or
    * `uptime_s` advanced by much less than the time that passed here: by
      less than half of it, and at least 10 s short. A process that
      restarted during a long gap can already be older than its predecessor
      was, with every total higher; its clock still cannot account for the
      gap.

  Rates are over the observer's clock, between the two moments the answers
  arrived.
  """

  @behaviour ObsFactor.Collector

  alias ObsFactor.Collector

  @version 1
  @timeout 2_000
  @max_body 4 * 1024 * 1024
  @max_units 100
  @max_members 20
  @max_streams 300
  @max_keys 100
  @max_string 120
  @max_events 50
  @max_message 300

  @impl true
  def name, do: :reports

  @impl true
  def init_state(opts) do
    %{targets: Keyword.fetch!(opts, :targets), token: Keyword.get(opts, :token), nodes: %{}}
  end

  @impl true
  def collect(%{targets: targets, token: token} = state) do
    started = System.system_time(:millisecond)

    {data, nodes} =
      targets
      |> Task.async_stream(
        fn {_id, url} ->
          result = fetch(url, token)
          {result, System.system_time(:millisecond)}
        end,
        max_concurrency: 32,
        timeout: @timeout + 1_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(targets)
      |> Enum.reduce({%{}, state.nodes}, fn {outcome, {id, _url}}, {data, nodes} ->
        {result, at_ms} =
          case outcome do
            {:ok, pair} -> pair
            {:exit, _} -> {{:error, "timed out"}, started}
          end

        {node_data, node_state} = step(Map.get(nodes, id, new_node()), result, at_ms)
        {Map.put(data, id, node_data), Map.put(nodes, id, node_state)}
      end)

    {:ok, data, %{state | nodes: nodes}}
  end

  @doc "GETs one report URL: `{:ok, reading}` or `{:error, reason}`."
  def fetch(url, token) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    case ObsFactor.Http.get(url, timeout: @timeout, decode: false, headers: headers) do
      {:ok, 200, body, _ms} -> parse(body)
      {:ok, status, _body, _ms} -> {:error, "answered #{status}"}
      {:error, message} -> {:error, message}
    end
  end

  @doc "What is remembered about a node between reads: nothing yet."
  def new_node, do: %{prev: nil, last_ok: nil}

  @doc """
  One read of one node. `result` is `{:ok, reading}` (from `parse/1` or
  `validate/1`) or `{:error, reason}`; `at_ms` is when the answer arrived.
  Returns `{node_data, node_state}`.

  A failed read keeps the previous good reading: the next good one is
  compared with it, over the longer interval, if it is still the same process.
  """
  def step(node_state, {:ok, reading}, at_ms) do
    reading = Map.put(reading, :at_ms, at_ms)
    at = DateTime.from_unix!(at_ms, :millisecond)
    rates = rates(node_state.prev, reading)

    data = %{
      ok: true,
      error: nil,
      at: at,
      restart: rates.restart,
      runtime: reading.runtime |> Map.delete(:counters) |> Map.put(:rates, rates.runtime),
      units: reading.units,
      streams: rates.streams,
      events: reading.events,
      truncated: reading.truncated
    }

    {data, %{node_state | prev: reading, last_ok: at}}
  end

  def step(node_state, {:error, reason}, _at_ms) do
    {%{ok: false, error: Collector.short(reason), at: node_state.last_ok}, node_state}
  end

  @doc """
  Rates between two readings of one node (each with `:at_ms`). `prev` nil
  (the first read) gives nil rates. Returns `%{restart, runtime, streams}`:
  `runtime` maps every counter of `cur` to its rate per second, `streams` is
  `cur`'s streams as `%{kind, name, by, count, rate, err_rate, avg_ms}`.

  A counter the previous reading did not have has no rate yet. A stream it
  did not have started from zero, unless the previous reading was truncated:
  then the stream may have been there all along, below the cut, and its rates
  are nil for this read.
  """
  def rates(nil, cur), do: unknown(cur, false)

  def rates(prev, cur) do
    dt_s = (cur.at_ms - prev.at_ms) / 1000
    prev_streams = Map.new(prev.streams, &{identity(&1), &1})
    restart = restart?(prev, prev_streams, cur, dt_s)

    if restart or dt_s <= 0 do
      unknown(cur, restart)
    else
      runtime =
        Map.new(cur.runtime.counters, fn {key, value} ->
          case prev.runtime.counters do
            %{^key => before} -> {key, (value - before) / dt_s}
            _ -> {key, nil}
          end
        end)

      zero = if prev.truncated.streams == 0, do: %{count: 0, errors: 0, duration_us: 0}

      streams =
        Enum.map(cur.streams, fn s ->
          case Map.get(prev_streams, identity(s), zero) do
            nil ->
              stream(s, nil, nil, nil)

            p ->
              d_count = s.count - p.count

              avg_ms =
                if d_count > 0, do: (s.duration_us - p.duration_us) / d_count / 1000, else: nil

              stream(s, d_count / dt_s, (s.errors - p.errors) / dt_s, avg_ms)
          end
        end)

      %{restart: false, runtime: runtime, streams: streams}
    end
  end

  # How far behind the observer's clock a report's uptime may fall before it
  # is another process: both conditions must hold.
  @uptime_short_s 10
  @uptime_short_fraction 0.5

  defp identity(s), do: {s.kind, s.name, s.by}

  defp restart?(prev, prev_streams, cur, dt_s) do
    advanced = cur.runtime.uptime_s - prev.runtime.uptime_s

    advanced < 0 or
      (advanced < dt_s * @uptime_short_fraction and dt_s - advanced >= @uptime_short_s) or
      Enum.any?(cur.runtime.counters, fn {key, value} ->
        case prev.runtime.counters do
          %{^key => before} -> value < before
          _ -> false
        end
      end) or
      Enum.any?(cur.streams, fn s ->
        case Map.get(prev_streams, identity(s)) do
          nil -> false
          p -> s.count < p.count or s.errors < p.errors or s.duration_us < p.duration_us
        end
      end)
  end

  defp unknown(cur, restart) do
    %{
      restart: restart,
      runtime: Map.new(cur.runtime.counters, fn {key, _} -> {key, nil} end),
      streams: Enum.map(cur.streams, &stream(&1, nil, nil, nil))
    }
  end

  defp stream(s, rate, err_rate, avg_ms) do
    %{
      kind: s.kind,
      name: s.name,
      by: s.by,
      count: s.count,
      rate: rate,
      err_rate: err_rate,
      avg_ms: avg_ms
    }
  end

  ## The document

  @doc "A response body to a reading: `{:ok, reading}` or `{:error, reason}`."
  def parse(body) when is_binary(body) do
    if byte_size(body) > @max_body do
      {:error, "report is #{byte_size(body)} bytes, more than #{@max_body}"}
    else
      case Jason.decode(body) do
        {:ok, doc} -> validate(doc)
        {:error, %Jason.DecodeError{position: at}} -> {:error, "malformed JSON at byte #{at}"}
      end
    end
  end

  @doc """
  Checks a decoded report and cuts it to the bounds in the moduledoc.
  `{:ok, reading}` or `{:error, reason}` naming the first thing that is wrong.

  A reading is `%{app, reported_at, runtime: %{kind, versions, uptime_s,
  gauges, counters}, units, streams, events, truncated}`; the open maps (`versions`,
  `gauges`, `counters`) keep the reporter's string keys.
  """
  def validate(doc) do
    {:ok, validate!(doc)}
  catch
    {:invalid, reason} -> {:error, reason}
  end

  defp validate!(doc) when is_map(doc) do
    case doc["factory_report"] do
      v when is_number(v) and v == @version -> :ok
      nil -> fail("factory_report is missing")
      v when is_number(v) -> fail("unknown factory_report version #{v}")
      v -> fail("factory_report is not a number: #{inspect(v, limit: 3, printable_limit: 40)}")
    end

    runtime = object!(doc["runtime"], "runtime")

    {units, cut_units} = doc["units"] |> list!("units") |> Enum.split(@max_units)

    {units, cut_members} =
      units
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {unit, i}, cut ->
        {unit, dropped} = unit!(unit, "units[#{i}]")
        {unit, cut + dropped}
      end)

    streams =
      doc["streams"]
      |> list!("streams")
      |> Enum.with_index()
      |> Enum.map(fn {s, i} -> stream!(s, "streams[#{i}]") end)
      # One row per kind + name + by; a reporter that repeats one is counted once.
      |> Enum.uniq_by(&identity/1)

    {streams, cut_streams} =
      if length(streams) > @max_streams do
        # Totals (no `by`) first, then breakdown rows, each busiest first.
        # Stable: among equal counts the reporter's order stands.
        {keep, cut} =
          streams |> Enum.sort_by(&{&1.by != nil, -&1.count}) |> Enum.split(@max_streams)

        {keep, length(cut)}
      else
        {streams, 0}
      end

    events =
      doc["events"]
      |> list!("events")
      |> Enum.take(@max_events)
      |> Enum.with_index()
      |> Enum.map(fn {e, i} -> event!(e, "events[#{i}]") end)

    truncated = optional_object!(doc["truncated"], "truncated")

    %{
      app: optional_string!(doc, "app", "app"),
      reported_at: optional_string!(doc, "at", "at"),
      runtime: %{
        kind: string!(runtime, "kind", "runtime.kind"),
        versions: versions(optional_object!(runtime["versions"], "runtime.versions")),
        uptime_s: count!(runtime, "uptime_s", "runtime.uptime_s"),
        gauges: numbers(runtime["gauges"], "runtime.gauges"),
        counters: numbers(runtime["counters"], "runtime.counters")
      },
      units: units,
      streams: streams,
      events: events,
      truncated: %{
        units: optional_count!(truncated, "units", "truncated.units") + length(cut_units),
        members: optional_count!(truncated, "members", "truncated.members") + cut_members,
        streams: optional_count!(truncated, "streams", "truncated.streams") + cut_streams
      }
    }
  end

  defp validate!(_other), do: fail("report is not a JSON object")

  defp unit!(unit, where) when is_map(unit) do
    {members, cut} = unit["members"] |> list!("#{where}.members") |> Enum.split(@max_members)

    members =
      members
      |> Enum.with_index()
      |> Enum.map(fn {m, i} -> member!(m, "#{where}.members[#{i}]") end)

    {%{
       kind: string!(unit, "kind", "#{where}.kind"),
       name: string!(unit, "name", "#{where}.name"),
       route: optional_string!(unit, "route", "#{where}.route"),
       count: count!(unit, "count", "#{where}.count"),
       gauges: numbers(unit["gauges"], "#{where}.gauges"),
       members: members
     }, length(cut)}
  end

  defp unit!(_other, where), do: fail("#{where} is not an object")

  defp member!(m, where) when is_map(m) do
    %{
      id: string!(m, "id", "#{where}.id"),
      label: optional_string!(m, "label", "#{where}.label"),
      since: optional_string!(m, "since", "#{where}.since"),
      gauges: numbers(m["gauges"], "#{where}.gauges"),
      counters: numbers(m["counters"], "#{where}.counters")
    }
  end

  defp member!(_other, where), do: fail("#{where} is not an object")

  defp stream!(s, where) when is_map(s) do
    %{
      kind: string!(s, "kind", "#{where}.kind"),
      name: string!(s, "name", "#{where}.name"),
      by: by!(s["by"], "#{where}.by"),
      count: count!(s, "count", "#{where}.count"),
      errors: count!(s, "errors", "#{where}.errors"),
      duration_us: count!(s, "duration_us", "#{where}.duration_us")
    }
  end

  defp stream!(_other, where), do: fail("#{where} is not an object")

  defp event!(e, where) when is_map(e) do
    %{
      at: string!(e, "at", "#{where}.at"),
      level: string!(e, "level", "#{where}.level"),
      name: optional_string!(e, "name", "#{where}.name"),
      message: e |> string!("message", "#{where}.message", @max_message),
      by: by!(e["by"], "#{where}.by")
    }
  end

  defp event!(_other, where), do: fail("#{where} is not an object")

  # Whose process caused it: a unit or a route, by kind and name.
  defp by!(nil, _where), do: nil

  defp by!(by, where) when is_map(by) do
    %{kind: string!(by, "kind", "#{where}.kind"), name: string!(by, "name", "#{where}.name")}
  end

  defp by!(_other, where), do: fail("#{where} is not an object")

  # An open `"key": number` map. Values that are not numbers are ignored; an
  # absent map is empty; anything else in its place is a wrong shape.
  defp numbers(map, where) do
    map
    |> optional_object!(where)
    |> Enum.filter(fn {_key, value} -> is_number(value) end)
    |> bounded()
  end

  defp versions(map) do
    map
    |> Enum.flat_map(fn
      {key, value} when is_binary(value) -> [{key, clip(value)}]
      {key, value} when is_number(value) -> [{key, to_string(value)}]
      _ -> []
    end)
    |> bounded()
  end

  # The first @max_keys keys in key order, so the same keys survive every read.
  defp bounded(pairs) do
    pairs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(@max_keys)
    |> Map.new(fn {key, value} -> {clip(key), value} end)
  end

  defp object!(map, _where) when is_map(map), do: map
  defp object!(nil, where), do: fail("#{where} is missing")
  defp object!(_other, where), do: fail("#{where} is not an object")

  defp optional_object!(nil, _where), do: %{}
  defp optional_object!(map, _where) when is_map(map), do: map
  defp optional_object!(_other, where), do: fail("#{where} is not an object")

  defp list!(nil, _where), do: []
  defp list!(list, _where) when is_list(list), do: list
  defp list!(_other, where), do: fail("#{where} is not a list")

  defp string!(map, key, where, max \\ @max_string) do
    case map[key] do
      s when is_binary(s) -> String.slice(s, 0, max)
      nil -> fail("#{where} is missing")
      _ -> fail("#{where} is not a string")
    end
  end

  defp optional_string!(map, key, where) do
    case map[key] do
      nil -> nil
      s when is_binary(s) -> clip(s)
      _ -> fail("#{where} is not a string")
    end
  end

  # A total or a size: a number that is not negative.
  defp count!(map, key, where) do
    case map[key] do
      n when is_number(n) and n >= 0 -> n
      nil -> fail("#{where} is missing")
      n when is_number(n) -> fail("#{where} is negative")
      _ -> fail("#{where} is not a number")
    end
  end

  defp optional_count!(map, key, where) do
    if map[key] == nil, do: 0, else: count!(map, key, where)
  end

  defp clip(s), do: String.slice(s, 0, @max_string)

  defp fail(reason), do: throw({:invalid, reason})
end
