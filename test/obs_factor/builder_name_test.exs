defmodule ObsFactor.Builder.NameTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Builder.Name

  # Cloudflare's v4 DNS records API, in memory: list by exact name, create,
  # patch, delete, with its {success, errors, result} envelope. Records the
  # requests it was sent.
  defmodule FakeCF do
    use Plug.Router
    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    def call(conn, {store, pid}), do: conn |> put_private(:store, store) |> put_private(:pid, pid) |> super([])

    defp ok(conn, result), do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{success: true, errors: [], result: result}))

    defp seen(conn) do
      send(conn.private.pid, {:cf, conn.method, conn.request_path, get_req_header(conn, "authorization"), conn.body_params})
      conn
    end

    get "/zones/z1/dns_records" do
      conn = conn |> fetch_query_params() |> seen()
      ok(conn, Enum.filter(Elixir.Agent.get(conn.private.store, &Map.values/1), &(&1["name"] == conn.query_params["name"])))
    end

    post "/zones/z1/dns_records" do
      conn = seen(conn)

      if conn.body_params["type"] == "A" and conn.body_params["content"] == "bad" do
        conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"success":false,"errors":[{"code":9005,"message":"Content for A record is invalid."}],"result":null}))
      else
        r = Map.put(conn.body_params, "id", "r#{System.unique_integer([:positive])}")
        Elixir.Agent.update(conn.private.store, &Map.put(&1, r["id"], r))
        ok(conn, r)
      end
    end

    patch "/zones/z1/dns_records/:id" do
      conn = seen(conn)
      r = Elixir.Agent.get_and_update(conn.private.store, fn s -> r = Map.merge(s[id], conn.body_params); {r, Map.put(s, id, r)} end)
      ok(conn, r)
    end

    delete "/zones/z1/dns_records/:id" do
      conn = seen(conn)
      Elixir.Agent.update(conn.private.store, &Map.delete(&1, id))
      ok(conn, %{id: id})
    end
  end

  setup do
    {:ok, store} = Elixir.Agent.start_link(fn -> %{} end)
    {:ok, pid} = Bandit.start_link(plug: {FakeCF, {store, self()}}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    cfg = %{
      dns_provider: "cloudflare",
      domain: "example.org",
      a_record_text: "203.0.113.7",
      cf: %{token: "cf-test-token", zone: "z1", api: "http://127.0.0.1:#{port}", proxied: false}
    }

    put_rec = fn r -> Elixir.Agent.update(store, &Map.put(&1, r["id"], r)) end
    records = fn -> Elixir.Agent.get(store, &Map.values/1) end
    %{cfg: cfg, put_rec: put_rec, records: records}
  end

  defp quiet, do: fn _ -> :ok end

  test "creates the A record with the marker, DNS-only, and the token as a bearer", %{cfg: cfg, records: records} do
    assert :ok = Name.write(cfg, "deci", "j1", quiet())
    assert [r] = records.()
    assert %{"type" => "A", "name" => "deci.example.org", "content" => "203.0.113.7", "proxied" => false, "ttl" => 60} = r
    assert r["comment"] == "obs_factor name=deci job=j1"
    assert_received {:cf, "GET", "/zones/z1/dns_records", ["Bearer cf-test-token"], _}
    assert_received {:cf, "POST", "/zones/z1/dns_records", _, _}
  end

  test "a rebuild updates its own record in place", %{cfg: cfg, put_rec: put_rec, records: records} do
    put_rec.(%{"id" => "a", "type" => "A", "name" => "deci.example.org", "content" => "198.51.100.1", "comment" => "obs_factor name=deci job=j0"})
    assert :ok = Name.write(cfg, "deci", "j2", quiet())
    assert [%{"id" => "a", "content" => "203.0.113.7", "comment" => "obs_factor name=deci job=j2"}] = records.()
    assert_received {:cf, "PATCH", "/zones/z1/dns_records/a", _, _}
  end

  test "a record it did not make, of any type, takes the name", %{cfg: cfg, put_rec: put_rec, records: records} do
    put_rec.(%{"id" => "m", "type" => "CNAME", "name" => "blog.example.org", "content" => "elsewhere.net", "comment" => nil})
    assert {:error, "blog.example.org is already in Cloudflare and the builder did not make it: CNAME elsewhere.net" <> _} = Name.write(cfg, "blog", "j1", quiet())
    assert [%{"id" => "m"}] = records.()
    refute_received {:cf, "POST", _, _, _}
  end

  test "delete removes only its own records", %{cfg: cfg, put_rec: put_rec, records: records} do
    put_rec.(%{"id" => "a", "type" => "A", "name" => "deci.example.org", "content" => "203.0.113.7", "comment" => "obs_factor name=deci job=j1"})
    put_rec.(%{"id" => "t", "type" => "TXT", "name" => "deci.example.org", "content" => "verify", "comment" => "someone's"})
    assert :ok = Name.delete(cfg, "deci")
    assert [%{"id" => "t"}] = records.()
  end

  test "Cloudflare's own error comes back with its code", %{cfg: cfg} do
    assert {:error, "Cloudflare POST /dns_records answered 400: 9005 Content for A record is invalid."} =
             Name.write(%{cfg | a_record_text: "bad"}, "deci", "j1", quiet())
  end

  test "proxied records use automatic TTL", %{cfg: cfg, records: records} do
    assert :ok = Name.write(put_in(cfg.cf.proxied, true), "deci", "j1", quiet())
    assert [%{"proxied" => true, "ttl" => 1}] = records.()
  end
end
