# A tiny Phoenix app for the tests: one endpoint, one router, a controller,
# a few LiveViews and a channel. Nothing here is part of the library.

defmodule FactoryReport.TestRepo do
  # What the library asks of an Ecto repo: its telemetry prefix.
  def config, do: [telemetry_prefix: [:test_app, :repo]]
end

# The things the library attributes, done by whoever calls run/1: a query and
# an outbound request (events of the shape Ecto and Finch emit), a custom
# event, a warning, and custom events from tasks one, two and three
# processes away.
defmodule FactoryReport.TestWork do
  require Logger

  def run(tag) do
    ms = System.convert_time_unit(1, :millisecond, :native)

    :telemetry.execute([:test_app, :repo, :query], %{total_time: 2 * ms}, %{
      repo: FactoryReport.TestRepo,
      result: {:ok, %{}}
    })

    :telemetry.execute([:finch, :request, :stop], %{duration: 3 * ms}, %{
      request: %{host: "api.example.com"},
      result: {:ok, %{status: 200}}
    })

    FactoryReport.event("work")
    Logger.warning("work warning from #{tag}", request_id: "req-#{tag}")

    task(fn -> FactoryReport.event("task1") end)
    task(fn -> task(fn -> FactoryReport.event("task2") end) end)
    task(fn -> task(fn -> task(fn -> FactoryReport.event("task3") end) end) end)
    :ok
  end

  defp task(fun), do: fun |> Task.async() |> Task.await()
end

# A :logger handler that hands each formatted line to a test process.
defmodule FactoryReport.TestSink do
  def log(event, %{formatter: {module, config}, config: %{pid: pid}}) do
    send(pid, {:line, IO.iodata_to_binary(module.format(event, config))})
  end
end

defmodule FactoryReport.TestController do
  use Phoenix.Controller, formats: [:html]

  def work(conn, _) do
    FactoryReport.TestWork.run("controller")
    text(conn, "done")
  end

  def hello(conn, %{"name" => name}), do: text(conn, "hello " <> name)
  def broken(conn, _), do: send_resp(conn, 500, "broken")
  def boom(_conn, _), do: raise("boom")
end

defmodule FactoryReport.TestErrorHTML do
  def render(template, _assigns), do: template
end

defmodule FactoryReport.TestLive.Counter do
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, n: 0)}

  def render(assigns) do
    ~H"""
    <p id="n">{@n}</p>
    <button phx-click="inc">+</button>
    {live_render(@socket, FactoryReport.TestLive.Child, id: "child")}
    """
  end

  def handle_event("inc", _, socket), do: {:noreply, update(socket, :n, &(&1 + 1))}
  def handle_event("crash", _, _socket), do: raise("crash")
end

defmodule FactoryReport.TestLive.Child do
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, socket}
  def render(assigns), do: ~H"<i>child</i>"
end

defmodule FactoryReport.TestLive.Room do
  use Phoenix.LiveView

  def mount(%{"id" => id}, _session, socket), do: {:ok, assign(socket, id: id)}
  def handle_params(%{"id" => id}, _uri, socket), do: {:noreply, assign(socket, id: id)}
  def render(assigns), do: ~H"<p>room {@id}</p>"
  def handle_event("ping", _, socket), do: {:noreply, socket}

  def handle_event("work", _, socket) do
    FactoryReport.TestWork.run("liveview")
    {:noreply, socket}
  end
end

# Subscribes to its feed's topic once connected, as LiveViews do.
defmodule FactoryReport.TestLive.Feed do
  use Phoenix.LiveView

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(FactoryReport.TestPubSub, "feed:" <> id)
    {:ok, assign(socket, id: id)}
  end

  def render(assigns), do: ~H"<p>feed {@id}</p>"
end

# No mount/3 and no handle_params/3: LiveView emits neither telemetry event.
defmodule FactoryReport.TestLive.Bare do
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p>bare</p>"
end

defmodule FactoryReport.TestRouter do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
  end

  scope "/" do
    pipe_through :browser

    get "/hello/:name", FactoryReport.TestController, :hello
    get "/work", FactoryReport.TestController, :work
    get "/broken", FactoryReport.TestController, :broken
    get "/boom", FactoryReport.TestController, :boom
    live "/counter", FactoryReport.TestLive.Counter
    live "/room/:id", FactoryReport.TestLive.Room
    live "/bare", FactoryReport.TestLive.Bare
    live "/feed/:id", FactoryReport.TestLive.Feed
  end
end

defmodule FactoryReport.TestChannel do
  use Phoenix.Channel

  def join("room:locked", _payload, _socket), do: {:error, %{reason: "locked"}}
  def join("room:" <> _id, _payload, socket), do: {:ok, socket}
  def handle_in("say", _payload, socket), do: {:reply, :ok, socket}
end

defmodule FactoryReport.TestSocket do
  use Phoenix.Socket

  channel "room:*", FactoryReport.TestChannel

  def connect(_params, socket, _info), do: {:ok, socket}
  def id(_socket), do: nil
end

defmodule FactoryReport.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :factory_report

  @session [store: :cookie, key: "_factory_report_test", signing_salt: "factory-report"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]
  socket "/socket", FactoryReport.TestSocket, websocket: true

  plug Plug.Session, @session
  plug FactoryReport.TestRouter
end
