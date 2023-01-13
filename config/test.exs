import Config

defmodule DBConfig do
  def config(db_url) when is_nil(db_url) do
    [
      username: "postgres",
      password: "postgres",
      database: "firezone_test",
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 64,
      queue_target: 1000
    ]
  end

  def config(db_url) do
    [
      url: db_url,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 64,
      queue_target: 1000
    ]
  end
end

# Configure your database
db_url = System.get_env("DATABASE_URL")
config :fz_http, FzHttp.Repo, DBConfig.config(db_url)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fz_http, FzHttpWeb.Endpoint,
  http: [port: 4002],
  secret_key_base: "t5hsQU868q6aaI9jsCrso9Qhi7A9Lvy5/NjCnJ8t8f652jtRjcBpYJkm96E8Q5Ko",
  live_view: [
    signing_salt: "mgC0uvbIgQM7GT5liNSbzJJhvjFjhb7t"
  ],
  server: true

config :fz_http,
  mock_events_module_errors: false,
  telemetry_module: FzCommon.MockTelemetry,
  supervision_tree_mode: :test,
  connectivity_checks_interval: 86_400,
  sql_sandbox: true,
  http_client: FzHttp.Mocks.HttpClient

# Print only warnings and errors during test
config :logger, level: :warn

config :ueberauth, Ueberauth,
  providers: [
    identity: {Ueberauth.Strategy.Identity, [callback_methods: ["POST"], uid_field: :email]}
  ]

config :fz_http, FzHttpWeb.Mailer, adapter: Swoosh.Adapters.Test, from_email: "test@firez.one"

config :fz_vpn,
  # XXX: Bump test coverage by adding a stubbed out module for FzVpn.StatsPushService
  supervised_children: [FzVpn.Interface.WGAdapter.Sandbox, FzVpn.Server],
  wg_adapter: FzVpn.Interface.WGAdapter.Sandbox

config :argon2_elixir, t_cost: 1, m_cost: 8

config :bureaucrat, :json_library, Jason

config :wallaby,
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  # XXX: Contribute to Wallaby to make this configurable on the per-process level,
  # along with buffer to write logs only on process failure
  js_logger: false

# config :ex_unit,
#   # exclude: if(!System.get_env("CI"), do: [:flaky, :webdriver, :integration]),
#   # formatters: [JUnitFormatter, ExUnit.CLIFormatter],
#   capture_log: true
