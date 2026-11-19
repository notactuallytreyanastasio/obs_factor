defmodule ObsFactor.Sites do
  @moduledoc """
  Static sites: for each subdirectory of `SITES_DIR`, the total size of its
  regular files and the newest mtime. Walks the tree, so it runs every couple
  of minutes, not every tick. Symlinks are not followed.
  """

  @behaviour ObsFactor.Collector

  @impl true
  def name, do: :sites

  @impl true
  def init_state(opts), do: %{dir: Keyword.get(opts, :dir)}

  @impl true
  def collect(%{dir: nil} = state), do: {:error, "SITES_DIR is not set", state}

  def collect(%{dir: dir} = state) do
    case File.ls(dir) do
      {:ok, names} ->
        sites =
          names
          |> Enum.sort()
          |> Enum.map(&{&1, Path.join(dir, &1)})
          |> Enum.filter(fn {_, path} ->
            match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
          end)
          |> Map.new(fn {name, path} -> {name, walk(path)} end)

        {:ok, sites, state}

      {:error, reason} ->
        {:error, "cannot list #{dir}: #{:file.format_error(reason)}", state}
    end
  end

  @doc "`%{bytes, files, newest_mtime}` for one directory tree."
  def walk(path) do
    acc = do_walk(path, %{bytes: 0, files: 0, newest: nil})

    %{
      bytes: acc.bytes,
      files: acc.files,
      newest_mtime: acc.newest && DateTime.from_unix!(acc.newest)
    }
  end

  defp do_walk(path, acc) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        %{acc | bytes: acc.bytes + size, files: acc.files + 1, newest: max_t(acc.newest, mtime)}

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            Enum.reduce(names, acc, &do_walk(Path.join(path, &1), &2))

          {:error, reason} ->
            raise File.Error, reason: reason, action: "list directory", path: path
        end

      {:ok, _other} ->
        acc

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stat", path: path
    end
  end

  defp max_t(nil, t), do: t
  defp max_t(a, b), do: max(a, b)
end
