Application.put_env(:factory_report, FactoryReport.TestEndpoint,
  secret_key_base: String.duplicate("factory-report-test-", 4),
  live_view: [signing_salt: "factory-report"],
  pubsub_server: FactoryReport.TestPubSub,
  render_errors: [formats: [html: FactoryReport.TestErrorHTML], layout: false],
  server: false
)

# Nothing on the console, but every level reaches the handlers under test.
:logger.remove_handler(:default)
Logger.configure(level: :debug)

{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: FactoryReport.TestPubSub}, FactoryReport.TestEndpoint],
    strategy: :one_for_one
  )

ExUnit.start()
