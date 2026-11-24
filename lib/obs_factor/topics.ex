defmodule ObsFactor.Topics do
  @moduledoc """
  The report's `pubsub` section (docs/contract.md, "PubSub"), on the
  observer's side: validated where the report is read
  (`ObsFactor.Reports`), summed over a cluster's members, and the same read
  of the observer's own VM.

  A server: `%{name, adapter, keys, partitions, topics, subscriptions,
  subscribers, top: [%{pattern, topics, subscriptions}], patterns_cut,
  counts_only, took_ms}`. `topics` and `subscribers` are nil when the
  reporter only counted (`counts_only` says why). At most 10 servers and 25
  patterns each; strings cut at 120 characters.

  The report never names a topic, only patterns (`room:#`): see
  `FactoryReport.PubSub`. Whole topics are read on demand through the
  observer (`observer:<node>:<member>:pubsub`).
  """

  @max_servers 10
  @max_top 25
  @max_string 120

  @doc """
  The `pubsub` of a decoded report: nil when absent (a reporter from before
  it), else a list of servers. Throws `{:invalid, reason}`, as
  `ObsFactor.Reports.validate/1` does, on a wrong shape.
  """
  def validate!(nil), do: nil

  def validate!(list) when is_list(list) do
    list
    |> Enum.take(@max_servers)
    |> Enum.with_index()
    |> Enum.map(fn {s, i} -> server!(s, "pubsub[#{i}]") end)
    |> Enum.uniq_by(& &1.name)
  end

  def validate!(_), do: fail("pubsub is not a list")

  defp server!(s, where) when is_map(s) do
    top =
      s
      |> Map.get("top", [])
      |> list!("#{where}.top")
      |> Enum.take(@max_top)
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        w = "#{where}.top[#{i}]"
        t = if is_map(t), do: t, else: fail("#{w} is not an object")
        %{pattern: string!(t, "pattern", w), topics: count!(t, "topics", w), subscriptions: count!(t, "subscriptions", w)}
      end)

    %{
      name: string!(s, "name", where),
      adapter: optional_string(s["adapter"]),
      keys: optional_string(s["keys"]),
      partitions: optional_count(s["partitions"]),
      topics: optional_count(s["topics"]),
      subscriptions: count!(s, "subscriptions", where),
      subscribers: optional_count(s["subscribers"]),
      top: top,
      patterns_cut: (optional_count(s["patterns_cut"]) || 0) + max(length(List.wrap(s["top"])) - @max_top, 0),
      counts_only: optional_string(s["counts_only"]),
      took_ms: optional_count(s["took_ms"])
    }
  end

  defp server!(_, where), do: fail("#{where} is not an object")

  @doc """
  A cluster's servers: summed by name over the members that reported one
  (nil when none did). Topics and patterns add up as the members count
  them, so a topic subscribed on two members is two topics here: each
  member's registry is its own.
  """
  def sum(datas) do
    lists = datas |> Enum.map(&Map.get(&1, :pubsub)) |> Enum.reject(&is_nil/1)

    if lists == [] do
      nil
    else
      lists
      |> List.flatten()
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {_, [s | _] = ss} ->
        add = fn key -> if Enum.any?(ss, &is_nil(Map.get(&1, key))), do: nil, else: ss |> Enum.map(&Map.get(&1, key)) |> Enum.sum() end

        {top, cut} =
          ss
          |> Enum.flat_map(& &1.top)
          |> Enum.group_by(& &1.pattern)
          |> Enum.map(fn {p, ts} -> %{pattern: p, topics: ts |> Enum.map(& &1.topics) |> Enum.sum(), subscriptions: ts |> Enum.map(& &1.subscriptions) |> Enum.sum()} end)
          |> Enum.sort_by(&{-&1.subscriptions, -&1.topics, &1.pattern})
          |> Enum.split(@max_top)

        %{
          s
          | topics: add.(:topics),
            subscriptions: add.(:subscriptions),
            subscribers: add.(:subscribers),
            top: top,
            patterns_cut: add.(:patterns_cut) + length(cut),
            counts_only: Enum.find_value(ss, & &1.counts_only),
            took_ms: ss |> Enum.map(& &1.took_ms) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
        }
      end)
      |> Enum.sort_by(& &1.name)
    end
  end

  @doc """
  The observer's own VM, read in-process as a report's section would be
  (`FactoryReport.PubSub.section/0`), as JSON-shaped maps (string keys), the
  way the wire reads a snapshot. Never raises: `[]` if the read fails.
  """
  def own do
    {servers, _cut} = FactoryReport.PubSub.section()
    servers
  rescue
    _ -> []
  end

  # ---- checks ------------------------------------------------------------------

  defp list!(l, _) when is_list(l), do: l
  defp list!(nil, _), do: []
  defp list!(_, where), do: fail("#{where} is not a list")

  defp string!(m, key, where) do
    case m[key] do
      s when is_binary(s) -> String.slice(s, 0, @max_string)
      nil -> fail("#{where}.#{key} is missing")
      _ -> fail("#{where}.#{key} is not a string")
    end
  end

  defp count!(m, key, where) do
    case m[key] do
      n when is_number(n) and n >= 0 -> n
      nil -> fail("#{where}.#{key} is missing")
      _ -> fail("#{where}.#{key} is not a number that is not negative")
    end
  end

  defp optional_string(s) when is_binary(s), do: String.slice(s, 0, @max_string)
  defp optional_string(_), do: nil

  defp optional_count(n) when is_number(n) and n >= 0, do: n
  defp optional_count(_), do: nil

  defp fail(reason), do: throw({:invalid, reason})
end
