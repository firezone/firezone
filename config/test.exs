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

config :fg_vpn,
  wireguard_conf_path: Path.expand("#{__DIR__}/../apps/fg_vpn/test/fixtures/wg-fireguard.conf")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fg_http, FgHttpWeb.Endpoint,
  http: [port: 4002],
  secret_key_base: "t5hsQU868q6aaI9jsCrso9Qhi7A9Lvy5/NjCnJ8t8f652jtRjcBpYJkm96E8Q5Ko",
  live_view: [
    signing_salt: "mgC0uvbIgQM7GT5liNSbzJJhvjFjhb7t"
  ],
  server: false

config :fg_vpn,
  privkey: "cAM9MY5NrQ067ZgOkE3NX3h7cMSOBRjj/w4acCuMknk=",
  pubkey: "DcAqEvFtS0wuvrpvOYi0ncDTcZKpdFq7LKHQcMuAzSw="

# Print only warnings and errors during test
config :logger, level: :warn
