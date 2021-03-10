# In this file, we load production configuration and secrets
# from environment variables. You can also hardcode secrets,
# although such is generally not recommended and you have to
# remember to add this file to your .gitignore.
import Config

# Required environment variables
database_url = System.fetch_env!("DATABASE_URL")
secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
live_view_signing_salt = System.fetch_env!("LIVE_VIEW_SIGNING_SALT")
ssl_cert_file = System.fetch_env!("SSL_CERT_FILE")
ssl_key_file = System.fetch_env!("SSL_KEY_FILE")

disable_signup =
  case System.get_env("DISABLE_SIGNUP") do
    d when d in ["1", "yes"] -> true
    _ -> false
  end

ssl_ca_cert_file =
  case System.get_env("SSL_CA_CERT_FILE") do
    "" -> nil
    s = _ -> s
  end

default_egress_address =
  FgVpn.CLI.Live.exec!("ip route get 8.8.8.8 | grep -oP 'src \\K\\S+'")
  |> String.trim()

# Optional environment variables
pool_size = String.to_integer(System.get_env("POOL_SIZE", "10"))
https_listen_port = String.to_integer(System.get_env("HTTPS_LISTEN_PORT", "8800"))
wg_listen_port = System.get_env("WG_LISTEN_PORT", "51820")
wg_endpoint_address = System.get_env("WG_ENDPOINT_ADDRESS", default_egress_address)
url_host = System.get_env("URL_HOST", "localhost")

config :fg_http,
  disable_signup: disable_signup

config :fg_http, FgHttp.Repo,
  # ssl: true,
  url: database_url,
  pool_size: pool_size

base_opts = [
  port: https_listen_port,
  transport_options: [max_connections: :infinity, socket_opts: [:inet6]],
  otp_app: :fireguard,
  keyfile: ssl_key_file,
  certfile: ssl_cert_file
]

https_opts = if ssl_ca_cert_file, do: base_opts ++ [cacertfile: ssl_ca_cert_file], else: base_opts

config :fg_http, FgHttpWeb.Endpoint,
  # Force SSL for releases
  https: https_opts,
  url: [host: url_host, port: https_listen_port],
  secret_key_base: secret_key_base,
  live_view: [
    signing_salt: live_view_signing_salt
  ]

config :fg_vpn,
  vpn_endpoint: wg_endpoint_address <> ":" <> wg_listen_port,
  private_key: File.read!("/opt/fireguard/server.key") |> String.trim()

# ## Using releases (Elixir v1.9+)
#
# If you are doing OTP releases, you need to instruct Phoenix
# to start each relevant endpoint:
#
config :fg_http, FgHttpWeb.Endpoint, server: true

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
      key: Base.decode64!(System.fetch_env!("DB_ENCRYPTION_KEY")),
      iv_length: 12
    }
  ]

#
# Then you can assemble a release by calling `mix release`.
# See `mix help release` for more information.
