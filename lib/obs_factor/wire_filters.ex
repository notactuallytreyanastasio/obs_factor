defmodule ObsFactor.WireFilters do
  @moduledoc """
  Saved filter sets for the BEAM wire (`ObsFactor.Wire`): a name and a spec,
  shared with everyone on the page, in the objectives database
  (`wire_filters`), next to the tape.

  A spec says which wire items to show; every part is optional and an
  empty part matches everything:

    * `apps`  - node ids (`"marginalia"`)
    * `sevs`  - `"alert" | "warn" | "info"`
    * `kinds` - wire kinds (`"restart"`, `"leader"`, `"mailbox"`, `"error"`, ...)
    * `q`     - text, matched case-insensitively against the headline, the
      detail and the member

  The browser applies a spec (board.js); the server keeps and checks it:
  lists of at most 50 strings of at most 80 characters, `q` at most 200.
  """

  alias ObsFactor.Tape

  @ddl """
  CREATE TABLE IF NOT EXISTS wire_filters (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    spec jsonb NOT NULL,
    by text,
    created_at timestamptz NOT NULL DEFAULT now()
  )
  """

  @doc "Creates the table if it is not there. `:ok` or `{:error, reason}`."
  def ensure(db \\ Tape.db()) do
    case q(db, @ddl, []) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  @doc "Every saved set, by name: `{:ok, [%{id, name, spec, by, created_at}]}`."
  def list(db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT id, name, spec, by, created_at FROM wire_filters ORDER BY lower(name), id", []) do
      {:ok, Enum.map(rows, &row/1)}
    end
  end

  @doc """
  Save a set (`%{"name", "spec", "by"}`), or change one (with `"id"`).
  `{:ok, set}` or `{:error, reason}`.
  """
  def save(attrs, db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, name} <- name(attrs["name"]),
         {:ok, spec} <- spec(attrs["spec"]) do
      by = if is_binary(attrs["by"]), do: String.slice(String.trim(attrs["by"]), 0, 60)

      result =
        case attrs["id"] do
          nil -> q(db, "INSERT INTO wire_filters (name, spec, by) VALUES ($1, $2, $3) RETURNING id, name, spec, by, created_at", [name, spec, by])
          id when is_integer(id) -> q(db, "UPDATE wire_filters SET name = $2, spec = $3 WHERE id = $1 RETURNING id, name, spec, by, created_at", [id, name, spec])
          other -> {:error, "a filter set id is an integer, got #{inspect(other)}"}
        end

      case result do
        {:ok, %{rows: [r]}} -> {:ok, row(r)}
        {:ok, %{rows: []}} -> {:error, "no filter set #{attrs["id"]}: deleted already?"}
        {:error, e} -> {:error, Tape.message(e)}
      end
    end
  end

  @doc "Delete a set. `{:ok, id}` or `{:error, reason}`."
  def delete(id, db \\ Tape.db())

  def delete(id, db) when is_integer(id) do
    with :ok <- ensure(db),
         {:ok, %{num_rows: 1}} <- q(db, "DELETE FROM wire_filters WHERE id = $1", [id]) do
      {:ok, id}
    else
      {:ok, %{num_rows: 0}} -> {:error, "no filter set #{id}"}
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  def delete(id, _), do: {:error, "a filter set id is an integer, got #{inspect(id)}"}

  @doc false
  def spec(s) when is_map(s) do
    with {:ok, apps} <- strings(s["apps"], "apps"),
         {:ok, sevs} <- strings(s["sevs"], "sevs"),
         {:ok, kinds} <- strings(s["kinds"], "kinds"),
         :ok <- if(Enum.all?(sevs, &(&1 in ~w(alert warn info))), do: :ok, else: {:error, "sevs are alert, warn or info, got #{inspect(sevs)}"}),
         {:ok, text} <- query(s["q"]) do
      {:ok, %{"apps" => apps, "sevs" => sevs, "kinds" => kinds, "q" => text}}
    end
  end

  def spec(other), do: {:error, "a spec is a map of apps, sevs, kinds and q, got #{inspect(other)}"}

  defp strings(nil, _), do: {:ok, []}

  defp strings(l, what) when is_list(l) and length(l) <= 50 do
    if Enum.all?(l, &(is_binary(&1) and byte_size(&1) in 1..80)),
      do: {:ok, Enum.uniq(l)},
      else: {:error, "#{what}: each one text of 1 to 80 characters"}
  end

  defp strings(_, what), do: {:error, "#{what}: a list of at most 50"}

  defp query(nil), do: {:ok, ""}
  defp query(t) when is_binary(t) and byte_size(t) <= 200, do: {:ok, String.trim(t)}
  defp query(_), do: {:error, "q: text of at most 200 characters"}

  defp name(n) when is_binary(n) do
    case String.trim(n) do
      "" -> {:error, "a filter set needs a name"}
      t -> {:ok, String.slice(t, 0, 60)}
    end
  end

  defp name(_), do: {:error, "a filter set needs a name"}

  defp row([id, name, spec, by, created]),
    do: %{id: id, name: name, spec: spec, by: by, created_at: DateTime.to_unix(created, :millisecond)}

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end
end
