# In this file, we load production configuration and secrets
# from environment variables. You can also hardcode secrets,
# although such is generally not recommended and you have to
# remember to add this file to your .gitignore.
import Config
alias FzCommon.CLI

# For releases, require that all these are set
database_name = System.fetch_env!("DATABASE_NAME")
database_user = System.fetch_env!("DATABASE_USER")
database_host = System.fetch_env!("DATABASE_HOST")
database_port = String.to_integer(System.fetch_env!("DATABASE_PORT"))
database_pool = String.to_integer(System.fetch_env!("DATABASE_POOL"))
port = String.to_integer(System.fetch_env!("PHOENIX_PORT"))
url_host = System.fetch_env!("URL_HOST")
admin_email = System.fetch_env!("ADMIN_EMAIL")
wireguard_interface_name = System.fetch_env!("WIREGUARD_INTERFACE_NAME")
wireguard_port = String.to_integer(System.fetch_env!("WIREGUARD_PORT"))

# secrets
encryption_key = System.fetch_env!("DATABASE_ENCRYPTION_KEY")
secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
live_view_signing_salt = System.fetch_env!("LIVE_VIEW_SIGNING_SALT")
private_key = System.fetch_env!("WIREGUARD_PRIVATE_KEY")

# Password is not needed if using bundled PostgreSQL, so use nil if it's not set.
database_password = System.get_env("DATABASE_PASSWORD")

config :fz_http,
  disable_signup: true

# Database configuration
connect_opts = [
  database: database_name,
  username: database_user,
  hostname: database_host,
  port: database_port,
  pool_size: database_pool,
  queue_target: 500
]

if database_password do
  config(:fz_http, FzHttp.Repo, connect_opts ++ [password: database_password])
else
  config(:fz_http, FzHttp.Repo, connect_opts)
end

config :fz_http, FzHttp.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      # In AES.GCM, it is important to specify 12-byte IV length for
      # interoperability with other encryption software. See this GitHub
      # issue for more details:
      # https://github.com/danielberkompas/cloak/issues/93
      #
      # In Cloak 2.0, this will be the default iv length for AES.GCM.
      tag: "AES.GCM.V1", key: Base.decode64!(encryption_key), iv_length: 12
    }
  ]

config :fz_http, FzHttpWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: port],
  server: true,
  url: [host: url_host, scheme: "https"],
  secret_key_base: secret_key_base,
  live_view: [
    signing_salt: live_view_signing_salt
  ]

config :fz_vpn,
  wireguard_interface_name: wireguard_interface_name,
  wireguard_port: wireguard_port,
  wireguard_private_key: private_key

config :fz_http,
  admin_email: admin_email
