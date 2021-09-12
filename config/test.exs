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

config :fz_http, :sql_sandbox, true
config :fz_http, :events_module, FzHttpWeb.MockEvents

# Print only warnings and errors during test
config :logger, level: :warn
