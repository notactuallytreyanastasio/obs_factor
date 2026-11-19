defmodule ObsFactor.Format do
  @moduledoc "Human strings for `facts` and attention texts."

  @units ["B", "KB", "MB", "GB", "TB"]

  @doc "Binary multiples, labelled the way people say them: 360448000 -> \"344 MB\"."
  def bytes(nil), do: "unknown"
  def bytes(n) when n < 1024, do: "#{round(n)} B"

  def bytes(n) do
    {value, unit} = scale(n / 1, @units)
    "#{num(value)} #{unit}"
  end

  defp scale(v, [unit]), do: {v, unit}
  defp scale(v, [unit | _]) when v < 1024, do: {v, unit}
  defp scale(v, [_ | rest]), do: scale(v / 1024, rest)

  def rate_bytes(nil), do: "unknown"
  def rate_bytes(n), do: bytes(n) <> "/s"

  @doc "Below 10 one decimal, otherwise whole: 1.5, 344."
  def num(v) when v < 10, do: v |> Float.round(1) |> trim_zero()
  def num(v), do: v |> round() |> Integer.to_string()

  defp trim_zero(f) do
    s = :erlang.float_to_binary(f, decimals: 1)
    if String.ends_with?(s, ".0"), do: String.trim_trailing(s, ".0"), else: s
  end

  def cores(nil), do: "unknown"
  def cores(c), do: "#{:erlang.float_to_binary(c / 1, decimals: 3)} cores"

  def rps(nil), do: "unknown"
  def rps(r), do: "#{:erlang.float_to_binary(r / 1, decimals: 2)} req/s"

  def percent(f), do: "#{round(f * 100)}%"

  def duration(nil), do: "unknown"

  def duration(s) when s < 120, do: "#{s} s"
  def duration(s) when s < 7200, do: "#{div(s, 60)} min"
  def duration(s) when s < 172_800, do: "#{div(s, 3600)} hours"
  def duration(s), do: "#{div(s, 86_400)} days"
end
