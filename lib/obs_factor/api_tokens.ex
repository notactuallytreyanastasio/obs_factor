defmodule ObsFactor.ApiTokens do
  @moduledoc """
  Tokens for scripts: what a cron job or curl sends as
  `Authorization: Bearer obsf_...` instead of logging in through the page.

  A token is 32 random bytes, url-safe, prefixed `obsf_` so it can be found
  in a leaked log. Only its SHA-256 is kept (`api_tokens`, in the
  objectives database), so the token is shown once, when it is made, and
  never again. Each has a name, the scopes it may use, who made it, and
  when it was last used. Revoking deletes it.

  Scopes: `writeups:read` (`GET /api/writeup.md`).
  """

  alias ObsFactor.Tape

  @scopes ~w(writeups:read)
  @prefix "obsf_"

  @ddl """
  CREATE TABLE IF NOT EXISTS api_tokens (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    hint text NOT NULL,
    hash bytea NOT NULL UNIQUE,
    scopes text[] NOT NULL,
    by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz
  )
  """

  def scopes, do: @scopes

  @doc "A new token: `{:ok, %{id, name, token, ...}}`; `token` is the only time it is shown."
  def create(name, scopes \\ @scopes, by \\ nil, db \\ Tape.db()) do
    with {:ok, name} <- text(name),
         :ok <- if(scopes != [] and Enum.all?(scopes, &(&1 in @scopes)), do: :ok, else: {:error, "scopes are #{Enum.join(@scopes, ", ")}"}),
         :ok <- ensure(db) do
      token = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      case q(db, "INSERT INTO api_tokens (name, hint, hash, scopes, by) VALUES ($1, $2, $3, $4, $5) RETURNING id, created_at",
             [name, String.slice(token, 0, 9) <> "…", hash(token), scopes, by]) do
        {:ok, %{rows: [[id, at]]}} -> {:ok, %{id: id, name: name, token: token, scopes: scopes, by: by, created_at: ms(at)}}
        {:error, e} -> {:error, Tape.message(e)}
      end
    end
  end

  @doc """
  Is this token good for `scope`? `{:ok, %{id, name}}` (and its last use
  is stamped) or `{:error, reason}`.
  """
  def verify(token, scope, db \\ Tape.db())

  def verify(@prefix <> _ = token, scope, db) do
    with :ok <- ensure(db),
         {:ok, %{rows: [[id, name, scopes]]}} <-
           q(db, "UPDATE api_tokens SET last_used_at = now() WHERE hash = $1 RETURNING id, name, scopes", [hash(token)]) do
      if scope in scopes, do: {:ok, %{id: id, name: name}}, else: {:error, "this token may not #{scope}"}
    else
      {:ok, %{rows: []}} -> {:error, "unknown or revoked token"}
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  def verify(_, _, _), do: {:error, "not an obs_factor token"}

  @doc "Every token, newest first, without the token itself."
  def list(db \\ Tape.db()) do
    with :ok <- ensure(db),
         {:ok, %{rows: rows}} <- q(db, "SELECT id, name, hint, scopes, by, created_at, last_used_at FROM api_tokens ORDER BY created_at DESC", []) do
      {:ok, for([id, n, h, s, by, c, u] <- rows, do: %{id: id, name: n, hint: h, scopes: s, by: by, created_at: ms(c), last_used_at: ms(u)})}
    end
  end

  def revoke(id, db \\ Tape.db())

  def revoke(id, db) when is_integer(id) do
    with :ok <- ensure(db),
         {:ok, %{num_rows: 1}} <- q(db, "DELETE FROM api_tokens WHERE id = $1", [id]) do
      {:ok, id}
    else
      {:ok, %{num_rows: 0}} -> {:error, "no token #{id}"}
      {:error, e} -> {:error, Tape.message(e)}
    end
  end

  def revoke(id, _), do: {:error, "a token id is an integer, got #{inspect(id)}"}

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp text(n) when is_binary(n) do
    case String.trim(n) do
      "" -> {:error, "a token needs a name (what will use it)"}
      t -> {:ok, String.slice(t, 0, 60)}
    end
  end

  defp text(_), do: {:error, "a token needs a name (what will use it)"}

  defp ensure(db) do
    case q(db, @ddl, []) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp q(db, sql, params) do
    Postgrex.query(db, sql, params)
  catch
    :exit, reason -> {:error, reason}
  end

  defp ms(nil), do: nil
  defp ms(%DateTime{} = d), do: DateTime.to_unix(d, :millisecond)
end
