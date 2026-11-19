defmodule Liveapp.MixProject do
  use Mix.Project

  # obslab's LiveView app: a real Phoenix app with a few LiveViews and
  # nothing else (no Ecto, no asset pipeline), there so the observer has a
  # building whose inside it can be told about by packages/factory_report.
  def project do
    [
      app: :liveapp,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {Liveapp.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.2"},
      {:factory_report, path: "../../packages/factory_report"}
    ]
  end
end
