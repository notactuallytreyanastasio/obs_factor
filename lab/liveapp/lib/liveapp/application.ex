defmodule Liveapp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Liveapp.PubSub},
      # The whole integration: this one child. It serves GET /report on its
      # own port, which the lab does not route through Caddy.
      {FactoryReport,
       app: :liveapp,
       port: String.to_integer(System.get_env("FACTORY_REPORT_PORT", "9568")),
       token: System.get_env("FACTORY_REPORT_TOKEN"),
       # lab-only: the observer reads /observer without a token here (the
       # port is reachable only on the lab's network)
       observer: true},
      LiveappWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Liveapp.Supervisor)
  end
end
