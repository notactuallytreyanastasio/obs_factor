defmodule ObsFactorWeb.WriteupController do
  @moduledoc """
  Writeups (`ObsFactor.Writeup`) over HTTP, for whatever is not the page: a
  script, a cron job, curl.

    * `GET /api/writeup.md` (behind the login) builds one and answers it as
      `text/markdown`, as a download. Parameters: `window` (a saved window's
      id) or `from` and `to` (unix ms); `set` (a saved wire filter set's
      id); `apps` (node ids, comma-separated); `sections` (comma-separated,
      of `ObsFactor.Writeup.sections/0`); `title`.
    * `GET /w/:slug.md` answers a saved writeup to anyone with the link, no
      login: that is what sharing one is. 404 for any other slug, revoked
      or never made, with nothing to tell them apart.
  """
  use ObsFactorWeb, :controller

  alias ObsFactor.Writeup

  def build(conn, params) do
    case Writeup.build(options(params) ++ [base_url: ObsFactorWeb.Endpoint.url()]) do
      {:ok, w} ->
        conn
        |> put_resp_content_type("text/markdown")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(w.title)}.md"))
        |> send_resp(200, w.markdown)

      {:error, e} ->
        conn |> put_status(400) |> json(%{error: ObsFactor.Tape.message(e)})
    end
  end

  def shared(conn, %{"slug" => file}) do
    slug = String.replace_suffix(file, ".md", "")

    case Writeup.fetch(slug) do
      {:ok, title, md} ->
        conn
        |> put_resp_content_type("text/markdown")
        |> put_resp_header("content-disposition", ~s(inline; filename="#{filename(title)}.md"))
        |> put_resp_header("x-robots-tag", "noindex")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, md)

      :none ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "no such writeup\n")
    end
  end

  @doc "Writeup options from string params (HTTP) or JSON (the channel)."
  def options(p) do
    [
      from: int(p["from"]),
      to: int(p["to"]),
      window: int(p["window"]),
      spec: set_spec(int(p["set"])) || (is_map(p["spec"]) && p["spec"]) || nil,
      apps: list(p["apps"]),
      sections: case list(p["sections"]) do [] -> nil; s -> s end,
      title: (is_binary(p["title"]) and String.trim(p["title"]) != "" && String.slice(String.trim(p["title"]), 0, 120)) || nil
    ]
    |> Enum.reject(fn {_, v} -> v in [nil, false] end)
  end

  defp set_spec(nil), do: nil

  defp set_spec(id) do
    case ObsFactor.WireFilters.list() do
      {:ok, sets} -> Enum.find_value(sets, &(&1.id == id && &1.spec))
      _ -> nil
    end
  end

  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp list(l) when is_list(l), do: Enum.filter(l, &is_binary/1)
  defp list(s) when is_binary(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  defp list(_), do: []

  defp filename(title), do: title |> String.replace(~r/[^\w.-]+/u, "-") |> String.trim("-") |> String.slice(0, 80)
end
