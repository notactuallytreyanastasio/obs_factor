defmodule ObsFactor.Writeup.Topics do
  @moduledoc """
  The writeup's "PubSub" section (`ObsFactor.Writeup`): each app's PubSub
  servers at the end of the range, as the last snapshot's `inside.pubsub`
  shows them, with their top topic patterns. Patterns, not topics: the
  report never names a topic (`FactoryReport.PubSub`).
  """

  @patterns 8

  @doc "Markdown, or nil when no app in `keep?` reports a PubSub server."
  def section(frame, keep?) do
    apps =
      for n <- frame["nodes"] || [], keep?.(n["id"]), servers = get_in(n, ["inside", "pubsub"]), is_list(servers), servers != [] do
        Enum.map_join(servers, "\n\n", fn s ->
          head = "### #{n["label"] || n["id"]}: #{s["name"]}\n\n#{counts(s)}"

          case s["top"] || [] do
            [] ->
              head

            top ->
              rows = Enum.map_join(Enum.take(top, @patterns), "\n", &"| `#{cell(&1["pattern"])}` | #{num(&1["topics"])} | #{num(&1["subscriptions"])} |")
              cut = length(top) - @patterns + (s["patterns_cut"] || 0)
              more = if cut > 0, do: "\n\n#{num(cut)} more pattern#{if cut == 1, do: "", else: "s"} not shown.", else: ""
              head <> "\n\n| Pattern | Topics | Subscriptions |\n|---|---:|---:|\n" <> rows <> more
          end
        end)
      end

    if apps != [] do
      Enum.join(
        ["## PubSub", "Each app's Phoenix.PubSub servers at the end of the range, and their busiest topic patterns (ids blanked to `#`: the report names no topic). Who is subscribed, and how fast topics are broadcast to, are not on the tape." | apps],
        "\n\n"
      )
    end
  end

  defp counts(%{"counts_only" => why} = s) when is_binary(why),
    do: "#{num(s["subscriptions"])} subscriptions; topics not counted (#{why})."

  defp counts(s),
    do: "#{num(s["topics"])} topics, #{num(s["subscriptions"])} subscriptions by #{num(s["subscribers"])} processes."

  defp cell(s), do: s |> to_string() |> String.replace("|", "\\|") |> String.replace("`", "'")

  defp num(nil), do: "–"
  defp num(n) when is_integer(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp num(n), do: n |> round() |> num()
end
