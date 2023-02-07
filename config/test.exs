import Config

config :fz_http, supervision_tree_mode: :test

partition_suffix =
  if partition = System.get_env("MIX_TEST_PARTITION") do
    "_p#{partition}"
  else
    ""
  end

config :fz_http, sql_sandbox: true

config :fz_http, FzHttp.Repo,
  database: "firezone_test#{partition_suffix}",
  pool: Ecto.Adapters.SQL.Sandbox

config :fz_http, FzHttpWeb.Endpoint, http: [port: 4002]

config :fz_http,
  http_client: FzHttp.Mocks.HttpClient

###############################
##### FZ VPN configs ##########
###############################

config :fz_vpn,
  # XXX: Bump test coverage by adding a stubbed out module for FzVpn.StatsPushService
  supervised_children: [FzVpn.Interface.WGAdapter.Sandbox, FzVpn.Server],
  wg_adapter: FzVpn.Interface.WGAdapter.Sandbox

###############################
##### Third-party configs #####
###############################
config :fz_http, FzHttpWeb.Mailer, adapter: FzHttpWeb.MailerTestAdapter

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
