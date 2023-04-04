import Config

###############################
##### Domain ##################
###############################

partition_suffix =
  if partition = System.get_env("MIX_TEST_PARTITION") do
    "_p#{partition}"
  else
    ""
  end

config :domain, sql_sandbox: true

config :domain, Domain.Repo,
  database: "firezone_test#{partition_suffix}",
  pool: Ecto.Adapters.SQL.Sandbox,
  queue_target: 1000

config :domain, Domain.Telemetry, enabled: false

config :domain, Domain.ConnectivityChecks, enabled: false

###############################
##### Web #####################
###############################

config :web, Web.Endpoint,
  http: [port: 13000],
  server: true

###############################
##### Third-party configs #####
###############################
config :web, Web.Mailer, adapter: Web.MailerTestAdapter

config :logger, level: :warn

config :argon2_elixir, t_cost: 1, m_cost: 8

config :bureaucrat, :json_library, Jason

config :wallaby,
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  # XXX: Contribute to Wallaby to make this configurable on the per-process level,
  # along with buffer to write logs only on process failure
  js_logger: false,
  hackney_options: [timeout: 10_000, recv_timeout: 10_000]

config :ex_unit,
  formatters: [JUnitFormatter, ExUnit.CLIFormatter],
  capture_log: true,
  exclude: [:acceptance]
