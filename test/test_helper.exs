# The Postgres-backed tests (objectives, tape, wire filters, writeups, tokens,
# schedules) all use OBJECTIVES_TEST_PG_URL, or the local default. Some of
# them only connect to it: they relied on another test module having created
# the database first, so on a fresh machine 10 failed depending on order.
# It is created here, once, before any test runs. No Postgres: the tests
# that need it say so themselves.
url = System.get_env("OBJECTIVES_TEST_PG_URL", "postgres://postgres:postgres@localhost/obs_factor_test")
uri = URI.parse(url)
db = String.trim_leading(uri.path || "", "/")
admin = %{uri | path: "/postgres"} |> URI.to_string()

try do
  {:ok, pid} =
    Postgrex.start_link(
      ObsFactor.Postgres.opts(admin, name: nil, pool_size: 1, statement_timeout: "5000")
      |> Keyword.delete(:name)
      |> Keyword.put(:backoff_type, :stop)
    )

  case Postgrex.query(pid, "SELECT 1 FROM pg_database WHERE datname = $1", [db]) do
    {:ok, %{num_rows: 0}} -> Postgrex.query!(pid, ~s(CREATE DATABASE "#{db}"), [])
    _ -> :ok
  end

  GenServer.stop(pid)
catch
  _, _ -> :ok
end

ExUnit.start()
