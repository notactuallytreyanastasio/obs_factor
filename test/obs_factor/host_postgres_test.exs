defmodule ObsFactor.HostPostgresTest do
  use ExUnit.Case, async: true

  alias ObsFactor.{Fixtures, Host, Postgres, Rate}

  describe "host" do
    test "the real /proc readings" do
      h = Fixtures.host()
      assert h.cores == 4
      assert_in_delta h.cpu_used_cores, 0.07558, 0.00001
      assert h.load1 == 0.04
      assert h.mem_total_bytes == 15_985_340 * 1024
      assert h.mem_used_bytes == (15_985_340 - 11_310_792) * 1024
    end

    test "disk from the real statvfs, df-style" do
      h = Fixtures.host()
      assert h.disk_total_bytes == 160_970_244_096
      assert h.disk_used_bytes == 133_432_082_432
      assert h.disk_avail_bytes == 20_938_870_784
      assert_in_delta ObsFactor.Rules.disk_fraction(h), 0.8644, 0.0001
    end

    test "no /proc is a clear error, not a number" do
      dir =
        Path.join(System.tmp_dir!(), "obs_factor_no_proc_#{System.unique_integer([:positive])}")

      state = Host.init_state(proc: dir, disk: "/")
      assert {:error, message, _} = Host.collect(state)
      assert message =~ "cannot read #{dir}/stat"
    end

    test "unset variables are named" do
      assert {:error, "HOST_PROC is not set", _} = Host.collect(Host.init_state([]))
    end

    test "statfs through coreutils stat where it exists, a located error where it does not" do
      gnu? = match?({_, 0}, System.cmd("stat", ["--version"], stderr_to_stdout: true))

      case Host.statfs(File.cwd!()) do
        {:ok, s} ->
          assert gnu?
          assert s.f_blocks > 0 and s.f_frsize > 0

        {:error, message} ->
          refute gnu?
          assert message =~ "statfs"
      end
    end
  end

  describe "postgres" do
    test "readings from the real pg_stat_database rows" do
      p = Fixtures.postgres()
      assert p.max_connections == 100
      assert p.connections == 96
      assert p.databases["blog_prod"].bytes == 2_594_723_507
      assert p.databases["blog_prod"].connections == 19
      assert p.databases["blog_prod"].commits_per_s == 10.0
      assert p.databases["tyler_prod"].commits_per_s == 0.0
      assert map_size(p.databases) == 9
    end

    test "first reading has no commit rate; a stats reset gives nil" do
      a = Postgres.reading(Fixtures.pg_rows(), 100, 96, 0)
      assert Postgres.rates(nil, a).databases["blog_prod"].commits_per_s == nil

      reset =
        Postgres.reading(
          Enum.map(Fixtures.pg_rows(), fn [n, s, b, _] -> [n, s, b, 0] end),
          100,
          96,
          5_000
        )

      assert Postgres.rates(a, reset).databases["blog_prod"].commits_per_s == nil
    end

    test "the connection is one Postgrex connection, pool_size 1" do
      spec = Postgres.connection_spec("postgres://blog:p%40ss@db:5432/postgres")
      {DBConnection.ConnectionPool, :start_link, [{Postgrex.Protocol, opts}]} = spec.start
      assert opts[:pool_size] == 1
      assert opts[:password] == "p@ss"
      assert opts[:hostname] == "db"
      assert opts[:database] == "postgres"
      assert Postgres.connection_spec(nil) == nil
    end
  end

  test "rate math" do
    assert Rate.per_second(10, 20, 5) == 2.0
    assert Rate.per_second(nil, 20, 5) == nil
    assert Rate.per_second(20, 10, 5) == nil
    assert Rate.per_second(10, 20, 0) == nil
  end
end
