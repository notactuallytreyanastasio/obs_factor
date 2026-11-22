defmodule LiveappWeb.HealthController do
  use Phoenix.Controller, formats: [:html]

  def show(conn, _params), do: text(conn, "ok")
end

defmodule LiveappWeb.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule LiveappWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>obslab liveapp</title>
        <style>
          body { font: 16px/1.5 system-ui, sans-serif; max-width: 34rem; margin: 3rem auto; padding: 0 1rem; }
          nav a { margin-right: 1rem; }
          button { font: inherit; padding: .3rem .9rem; }
          .big { font-size: 3rem; font-variant-numeric: tabular-nums; margin: 1rem 0; }
        </style>
      </head>
      <body>
        <nav>
          <a href="/">counter</a>
          <a href="/clock">clock</a>
          <a href="/room/lobby">room lobby</a>
          <a href="/room/42">room 42</a>
        </nav>
        {@inner_content}
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script>
          const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrf}});
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end
end
