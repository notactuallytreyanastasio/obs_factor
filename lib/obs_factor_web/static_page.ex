defmodule ObsFactorWeb.StaticPage do
  @moduledoc """
  Serves an HTML file the frontend writes under `priv/static/`. The file is
  read per request; if it is not there the answer is a 500 naming it, never a
  page of our own.

  Asset URLs in it are stamped with a hash of everything under `assets/`
  (`/assets/js/main.js?v=…`), and an import map sends each module's relative
  imports (`./beam.js`) to the same stamped URL. Cloudflare sits in front in
  production and keeps `.js` and `.css` for hours under their plain URL: the
  page itself is `no-store`, so without the stamp a deploy served new HTML
  over the previous deploy's scripts (2026-11-22: a new index.html running an
  old main.js, so "Under the hood" did nothing).
  """

  import Plug.Conn

  def send_page(conn, file) do
    dir =
      Application.get_env(:obs_factor, :pages_dir) ||
        Application.app_dir(:obs_factor, "priv/static")

    path = Path.join(dir, file)

    case File.read(path) do
      {:ok, html} ->
        html = stamp(html, Path.join(dir, "assets"))

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

  @doc false
  # The HTML with /assets/... URLs versioned by the assets' content hash. No
  # assets directory: the HTML as it is.
  def stamp(html, assets_dir) do
    case asset_files(assets_dir) do
      [] ->
        html

      files ->
        v = version(assets_dir, files)

        map =
          for f <- files, String.ends_with?(f, ".js"), into: %{} do
            {"/assets/" <> f, "/assets/#{f}?v=#{v}"}
          end

        importmap = ~s(<script type="importmap">#{Jason.encode!(%{imports: map})}</script>\n  )

        html
        |> String.replace(~r{((?:src|href)="/assets/[^"?]+)"}, "\\1?v=#{v}\"")
        |> String.replace(~r{<script type="module"}, importmap <> "<script type=\"module\"", global: false)
    end
  end

  defp asset_files(dir) do
    if File.dir?(dir) do
      Path.wildcard(Path.join(dir, "**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.reject(&String.ends_with?(&1, ".gz"))
      |> Enum.sort()
    else
      []
    end
  end

  defp version(dir, files) do
    files
    |> Enum.reduce(:crypto.hash_init(:sha256), fn f, acc ->
      acc |> :crypto.hash_update(f) |> :crypto.hash_update(File.read!(Path.join(dir, f)))
    end)
    |> :crypto.hash_final()
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 10)
  end
end
