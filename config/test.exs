import Config

defmodule DBConfig do
  def config(db_url) when is_nil(db_url) do
    [
      username: "postgres",
      password: "postgres",
      database: "cloudfire_test",
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
config :cf_http, CfHttp.Repo, DBConfig.config(db_url)

config :cf_http, CfHttp.Mailer, adapter: Bamboo.TestAdapter

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cf_http, CfHttpWeb.Endpoint,
  http: [port: 4002],
  secret_key_base: "t5hsQU868q6aaI9jsCrso9Qhi7A9Lvy5/NjCnJ8t8f652jtRjcBpYJkm96E8Q5Ko",
  live_view: [
    signing_salt: "mgC0uvbIgQM7GT5liNSbzJJhvjFjhb7t"
  ],
  server: true

config :cf_http, :sql_sandbox, true
config :cf_http, :events_module, CfHttpWeb.MockEvents

# Print only warnings and errors during test
config :logger, level: :warn

config :cf_vpn,
  execute_iface_cmds: System.get_env("CI") === "true"

config :cf_common, :config_file_module, CfCommon.FakeFile
