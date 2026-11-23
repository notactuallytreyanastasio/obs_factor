defmodule ObsFactor.Postgres do
  @moduledoc """
  Postgres collector. The box runs at ~96 of 100 connections, so the observer
  holds exactly one: a single Postgrex connection (`pool_size: 1`), started as
  its own supervised child (`ObsFactor.Postgres.Conn`) so that a crash of this
  collector never opens a second one. No Ecto, no database of our own.

  Per tick, two queries on that connection: per-database size, backends and
  commit counter; and total client connections against `max_connections`.
  """

  @behaviour ObsFactor.Collector

  alias ObsFactor.Rate

  @conn ObsFactor.Postgres.Conn

  # pg_database_size needs CONNECT on the database or membership of
  # pg_read_all_stats (the lab's observer role is IN ROLE pg_monitor, which
  # includes it). Without either the size is unknown (NULL) rather than
  # failing the whole query.
  @databases_sql """
  SELECT d.datname,
         CASE WHEN has_database_privilege(d.datname, 'CONNECT')
                   OR pg_has_role('pg_read_all_stats', 'MEMBER')
              THEN pg_database_size(d.datname) END,
         s.numbackends,
         s.xact_commit
    FROM pg_database d
    JOIN pg_stat_database s ON s.datid = d.oid
   WHERE NOT d.datistemplate
   ORDER BY d.datname
  """

  @connections_sql """
  SELECT current_setting('max_connections')::int,
         (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend')::int
  """

  @doc "Child spec for the one connection, or nil when PG_URL is unset."
  def connection_spec(nil), do: nil

  def connection_spec(url) do
    Supervisor.child_spec({Postgrex, opts(url, name: @conn, pool_size: 1, statement_timeout: "3000")}, id: @conn)
  end

  @doc """
  Postgrex options for a postgres:// URL (also the objectives store's).
  `name`, `pool_size`, `statement_timeout` and `application_name` from `extra`.
  """
  def opts(url, extra) do
    uri = URI.parse(url)

    unless uri.scheme in ["postgres", "postgresql"] and uri.host do
      raise ArgumentError, "PG_URL must look like postgres://user:pw@host:port/db"
    end

    {user, password} =
      case String.split(uri.userinfo || "", ":", parts: 2) do
        [u, p] -> {URI.decode(u), URI.decode(p)}
        [u] -> {URI.decode(u), nil}
      end

    [
      name: Keyword.fetch!(extra, :name),
      hostname: uri.host,
      port: uri.port || 5432,
      username: user,
      database: String.trim_leading(uri.path || "/postgres", "/"),
      pool_size: Keyword.fetch!(extra, :pool_size),
      backoff_min: 2_000,
      backoff_max: 30_000,
      parameters: [
        application_name: Keyword.get(extra, :application_name, "obs_factor"),
        statement_timeout: Keyword.fetch!(extra, :statement_timeout)
      ]
    ]
    |> then(&if(password, do: Keyword.put(&1, :password, password), else: &1))
  end

  @impl true
  def name, do: :postgres

  @impl true
  def init_state(opts), do: %{configured: Keyword.get(opts, :url) != nil, prev: nil}

  @impl true
  def collect(%{configured: false} = state), do: {:error, "PG_URL is not set", state}

  def collect(state) do
    with {:ok, %{rows: db_rows}} <- Postgrex.query(@conn, @databases_sql, [], timeout: 3_000),
         {:ok, %{rows: [[max, used]]}} <-
           Postgrex.query(@conn, @connections_sql, [], timeout: 3_000) do
      reading = reading(db_rows, max, used, System.system_time(:millisecond))
      {:ok, rates(state.prev, reading), %{state | prev: reading}}
    else
      {:error, %{postgres: %{message: m}}} ->
        {:error, "postgres: #{m}", state}

      {:error, e} when is_exception(e) ->
        {:error, ObsFactor.Collector.short(Exception.message(e)), state}
    end
  end

  @doc "A reading from rows `[datname, size_bytes | nil, numbackends, xact_commit]`."
  def reading(rows, max_connections, connections, at_ms) do
    databases =
      Map.new(rows, fn [name, size, backends, commits] ->
        {name, %{bytes: size, connections: backends, commits: commits}}
      end)

    %{
      at_ms: at_ms,
      databases: databases,
      max_connections: max_connections,
      connections: connections
    }
  end

  @doc "Commit rates between readings; a reset stats counter gives nil."
  def rates(prev, cur) do
    dt_s = if prev, do: (cur.at_ms - prev.at_ms) / 1000, else: 0

    databases =
      Map.new(cur.databases, fn {name, d} ->
        p = prev && prev.databases[name]
        {name, Map.put(d, :commits_per_s, Rate.per_second(p && p.commits, d.commits, dt_s))}
      end)

    %{databases: databases, max_connections: cur.max_connections, connections: cur.connections}
  end
end
