defmodule ObsFactorWeb.StreamTest do
  # A real HTTP server (Bandit on a free port) because SSE is a long response.
  use ExUnit.Case, async: false

  alias ObsFactor.Store

  setup do
    {:ok, pid} =
      Bandit.start_link(plug: ObsFactorWeb.Endpoint, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    on_exit(fn -> Process.exit(pid, :normal) end)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  test "an immediate snapshot on connect, then one per broadcast", %{base: base} do
    Store.put_snapshot({:ok, ~s({"at":"first"})})

    login =
      Req.post!(base <> "/login",
        form: [password: "correct horse battery staple"],
        redirect: false,
        retry: false
      )

    assert login.status == 302
    [cookie | _] = login.headers["set-cookie"]
    cookie = cookie |> String.split(";") |> hd()

    resp = Req.get!(base <> "/api/stream", headers: [cookie: cookie], into: :self, retry: false)
    assert resp.status == 200
    assert ["text/event-stream" <> _] = resp.headers["content-type"]

    assert next_chunk(resp) == ~s(event: snapshot\ndata: {"at":"first"}\n\n)

    Phoenix.PubSub.broadcast(
      ObsFactor.PubSub,
      ObsFactor.Ticker.topic(),
      {:snapshot, ~s({"at":"second"})}
    )

    assert next_chunk(resp) == ~s(event: snapshot\ndata: {"at":"second"}\n\n)
  end

  test "without a session the stream is 401", %{base: base} do
    resp = Req.get!(base <> "/api/stream", retry: false)
    assert resp.status == 401
  end

  defp next_chunk(resp) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, [data: data]} -> data
          {:ok, other} -> flunk("unexpected #{inspect(other)}")
          :unknown -> next_chunk(resp)
        end
    after
      2_000 -> flunk("no SSE chunk within 2 s")
    end
  end
end
