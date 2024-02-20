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

config :domain, platform_adapter: Domain.GoogleCloudPlatform

config :domain, Domain.GoogleCloudPlatform,
  project_id: "fz-test",
  service_account_email: "foo@iam.example.com"

###############################
##### Web #####################
###############################

config :web, Web.Endpoint,
  http: [port: 13_100],
  url: [port: 13_100],
  server: true

config :web, Web.Plugs.SecureHeaders,
  csp_policy: [
    "default-src 'self' 'nonce-${nonce}' https://cdn.tailwindcss.com/",
    "img-src 'self' data: https://www.gravatar.com",
    "style-src 'self' 'unsafe-inline'",
    "frame-src 'self' https://js.stripe.com",
    "script-src 'self' 'unsafe-inline' https://js.stripe.com https://cdn.tailwindcss.com/"
  ]

###############################
##### API #####################
###############################

config :api, API.Endpoint,
  http: [port: 13_101],
  url: [port: 13_101],
  server: true

###############################
##### Third-party configs #####
###############################
config :web, Web.Mailer, adapter: Web.Mailer.TestAdapter

config :logger, level: :warning

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

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
