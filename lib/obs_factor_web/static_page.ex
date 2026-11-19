defmodule ObsFactorWeb.StaticPage do
  @moduledoc """
  Serves an HTML file the frontend writes under `priv/static/`. The file is
  read per request; if it is not there the answer is a 500 naming it, never a
  page of our own.
  """

  import Plug.Conn

  def send_page(conn, file) do
    dir =
      Application.get_env(:obs_factor, :pages_dir) ||
        Application.app_dir(:obs_factor, "priv/static")

    path = Path.join(dir, file)

    case File.read(path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, html)

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          500,
          "priv/static/#{file} is missing (#{:file.format_error(reason)}): the frontend has not written it\n"
        )
    end
  end
end
