import Config

defmodule DBConfig do
  def config(db_url) when is_nil(db_url) do
    [
      username: "fireguard",
      password: "postgres",
      database: "fireguard_test",
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      pool: Ecto.Adapters.SQL.Sandbox
    ]
  end

  def config(db_url) do
    [
      url: db_url,
      pool: Ecto.Adapters.SQL.Sandbox
    ]
  end
end

# Configure your database
db_url = System.get_env("DATABASE_URL")
config :fg_http, FgHttp.Repo, DBConfig.config(db_url)

config :fg_http, FgHttp.Mailer, adapter: Bamboo.TestAdapter

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fg_http, FgHttpWeb.Endpoint,
  http: [port: 4002],
  secret_key_base: "t5hsQU868q6aaI9jsCrso9Qhi7A9Lvy5/NjCnJ8t8f652jtRjcBpYJkm96E8Q5Ko",
  live_view: [
    signing_salt: "mgC0uvbIgQM7GT5liNSbzJJhvjFjhb7t"
  ],
  server: true

config :fg_http, :sql_sandbox, true
config :wallaby, otp_app: :fg_http
config :fg_http, :event_helpers_module, FgHttpWeb.MockEvents

# Print only warnings and errors during test
config :logger, level: :warn

config :fg_vpn,
  execute_iface_cmds: System.get_env("CI") === "true"

config :fg_http, FgHttp.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      # In AES.GCM, it is important to specify 12-byte IV length for
      # interoperability with other encryption software. See this GitHub
      # issue for more details:
      # https://github.com/danielberkompas/cloak/issues/93
      #
      # In Cloak 2.0, this will be the default iv length for AES.GCM.
      tag: "AES.GCM.V1",
      key: Base.decode64!("XXJ/NGevpvkG9219RYsz21zZWR7CZ//CqA0ARPIBqys="),
      iv_length: 12
    }
  ]
