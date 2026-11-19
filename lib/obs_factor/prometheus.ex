defmodule ObsFactor.Prometheus do
  @moduledoc """
  Parser for the Prometheus text exposition format (what Caddy serves on its
  metrics endpoint). Returns `[{name, labels, value}]`; comment lines are
  skipped. A line that does not parse raises with the line.
  """

  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&line/1)
  end

  defp line(l) do
    case Regex.run(~r/^([a-zA-Z_:][a-zA-Z0-9_:]*)(.*)$/, l) do
      [_, name, rest] ->
        {labels, rest} = labels(rest, l)

        value =
          case String.split(String.trim(rest), ~r/\s+/) do
            [v | _] -> number(v, l)
            _ -> raise ArgumentError, "metrics line without a value: #{inspect(l)}"
          end

        {name, labels, value}

      _ ->
        raise ArgumentError, "unparseable metrics line: #{inspect(l)}"
    end
  end

  defp labels("{" <> rest, l), do: label_pairs(rest, %{}, l)
  defp labels(rest, _l), do: {%{}, rest}

  defp label_pairs("}" <> rest, acc, _l), do: {acc, rest}
  defp label_pairs("," <> rest, acc, l), do: label_pairs(rest, acc, l)

  defp label_pairs(s, acc, l) do
    case Regex.run(~r/^\s*([a-zA-Z_][a-zA-Z0-9_]*)="/, s) do
      [whole, key] ->
        {value, rest} =
          quoted(binary_part(s, byte_size(whole), byte_size(s) - byte_size(whole)), [], l)

        label_pairs(rest, Map.put(acc, key, value), l)

      _ ->
        raise ArgumentError, "bad label set in metrics line: #{inspect(l)}"
    end
  end

  defp quoted(~S(\\) <> rest, acc, l), do: quoted(rest, ["\\" | acc], l)
  defp quoted(~S(\") <> rest, acc, l), do: quoted(rest, ["\"" | acc], l)
  defp quoted(~S(\n) <> rest, acc, l), do: quoted(rest, ["\n" | acc], l)
  defp quoted("\"" <> rest, acc, _l), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp quoted(<<c::utf8, rest::binary>>, acc, l), do: quoted(rest, [<<c::utf8>> | acc], l)
  defp quoted("", _acc, l), do: raise(ArgumentError, "unterminated label value: #{inspect(l)}")

  defp number("+Inf", _), do: :infinity
  defp number("-Inf", _), do: :neg_infinity
  defp number("NaN", _), do: :nan

  defp number(v, l) do
    case Float.parse(v) do
      {f, ""} -> f
      _ -> raise ArgumentError, "bad sample value #{inspect(v)} in #{inspect(l)}"
    end
  end
end
