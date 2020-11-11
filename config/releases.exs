# In this file, we load production configuration and secrets
# from environment variables. You can also hardcode secrets,
# although such is generally not recommended and you have to
# remember to add this file to your .gitignore.
import Config

# Required environment variables
database_url =
  System.get_env("DATABASE_URL") ||
    raise """
    Environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    raise """
    Environment variable SECRET_KEY_BASE is missing.
    Please generate with "openssl rand -base64 48" and add to
    /opt/fireguard/config.env
    """

live_view_signing_salt =
  System.get_env("LIVE_VIEW_SIGNING_SALT") ||
    raise """
    Environment variable LIVE_VIEW_SIGNING_SALT is missing.
    Please generate with "openssl rand -base64 24" and add to
    /opt/fireguard/config.env
    """

pubkey =
  System.get_env("PUBKEY") ||
    raise """
    Environment variable PUBKEY is missing. Please generate
    with the "wg" utility.
    """

ssl_cert_file =
  System.get_env("SSL_CERT_FILE") ||
    raise """
    Environment variable SSL_CERT_FILE is missing. FireGuard requires SSL.
    """

ssl_key_file =
  System.get_env("SSL_KEY_FILE") ||
    raise """
    Environment variable SSL_KEY_FILE is missing. FireGuard requires SSL.
    """

ssl_ca_cert_file = System.get_env("SSL_CA_CERT_FILE")

# Optional environment variables
pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")
listen_port = String.to_integer(System.get_env("LISTEN_PORT") || "8800")
url_host = System.get_env("URL_HOST") || "localhost"

config :fg_vpn, pubkey: pubkey

config :fg_http, FgHttp.Repo,
  # ssl: true,
  url: database_url,
  pool_size: pool_size

base_opts = [
  port: listen_port,
  transport_options: [socket_opts: [:inet6]],
  cipher_suite: :strong,
  otp_app: :fireguard,
  keyfile: ssl_key_file,
  certfile: ssl_cert_file
]

https_opts = if ssl_ca_cert_file, do: base_opts ++ [cacertfile: ssl_ca_cert_file], else: base_opts

config :fg_http, FgHttpWeb.Endpoint,
  # Force SSL for releases
  https: https_opts,
  url: [host: url_host, port: listen_port],
  secret_key_base: secret_key_base,
  live_view: [
    signing_salt: live_view_signing_salt
  ]

# ## Using releases (Elixir v1.9+)
#
# If you are doing OTP releases, you need to instruct Phoenix
# to start each relevant endpoint:
#
config :fg_http, FgHttpWeb.Endpoint, server: true
#
# Then you can assemble a release by calling `mix release`.
# See `mix help release` for more information.
