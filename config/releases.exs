# In this file, we load production configuration and secrets
# from environment variables. You can also hardcode secrets,
# although such is generally not recommended and you have to
# remember to add this file to your .gitignore.
import Config

config_file_path = "/opt/fireguard/config.yaml"
yaml_config = YamlElixir.read_from_file!(config_file_path)

database_url =
  System.get_env("DATABASE_URL") || yaml_config["database_url"] ||
    raise """
    config option database_url or environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

secret_key_base =
  System.get_env("SECRET_KEY_BASE") || yaml_config["secret_key_base"] ||
    raise """
    config option secret_key_base or environment variable SECRET_KEY_BASE is missing.
    """

live_view_signing_salt =
  System.get_env("LIVE_VIEW_SIGNING_SALT") || yaml_config["live_view_signing_salt"] ||
    raise """
    config option live_view_signing_salt or environment variable LIVE_VIEW_SIGNING_SALT is
    missing.
    """

pool_size = yaml_config["pool_size"] || String.to_integer(System.get_env("POOL_SIZE") || "10")

listen_port =
  yaml_config["listen_port"] || String.to_integer(System.get_env("LISTEN_PORT") || "4000")

listen_host = yaml_config["listen_host"] || System.get_env("LISTEN_HOST") || "localhost"

config :fg_vpn,
  pubkey: yaml_config["pubkey"]

config :fg_http, FgHttp.Repo,
  # ssl: true,
  url: database_url,
  pool_size: pool_size

config :fg_http, FgHttpWeb.Endpoint,
  http: [
    port: listen_port,
    transport_options: [socket_opts: [:inet6]]
  ],
  url: [host: listen_host, port: listen_port],
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
