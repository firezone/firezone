import Config

defmodule DBConfig do
  def config(db_url) when is_nil(db_url) do
    [
      username: "postgres",
      password: "postgres",
      database: "cloudfire_test",
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
config :cf_http, CfHttp.Repo, DBConfig.config(db_url)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cf_http, CfHttpWeb.Endpoint,
  http: [port: 4002],
  server: false

# Print only warnings and errors during test
config :logger, level: :warn
