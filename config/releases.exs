# In this file, we load production configuration and secrets
# from environment variables. You can also hardcode secrets,
# although such is generally not recommended and you have to
# remember to add this file to your .gitignore.
import Config
alias CfCommon.{CLI, ConfigFile}

config_file =
  if ConfigFile.exists?() do
    ConfigFile.load!()
  else
    ConfigFile.init!()
  end

# Required environment variables
database_url = Map.fetch!(config_file, "database_url")
secret_key_base = Map.fetch!(config_file, "secret_key_base")
live_view_signing_salt = Map.fetch!(config_file, "live_view_signing_salt")
ssl_cert_file = Map.fetch!(config_file, "ssl_cert_file")
ssl_key_file = Map.fetch!(config_file, "ssl_key_file")

disable_signup =
  case config_file["disable_signup"] do
    d when d in ["1", "yes"] -> true
    _ -> false
  end

ssl_ca_cert_file =
  case config_file["ssl_ca_cert_file"] do
    "" -> nil
    s = _ -> s
  end

default_egress_address =
  CLI.exec!("ip route get 8.8.8.8 | grep -oP 'src \\K\\S+'")
  |> String.trim()

# Optional environment variables
pool_size = max(:erlang.system_info(:logical_processors_available), 10)
queue_target = 500
https_listen_port = String.to_integer(Map.get(config_file, "https_listen_port", "8800"))
wg_listen_port = Map.get(config_file, "wg_listen_port", "51820")
wg_endpoint_address = Map.get(config_file, "wg_endpoint_address", default_egress_address)
url_host = Map.get(config_file, "url_host", "localhost")

config :cf_http,
  disable_signup: disable_signup

config :cf_http, CfHttp.Repo,
  # ssl: true,
  url: database_url,
  pool_size: pool_size,
  queue_target: queue_target

base_opts = [
  port: https_listen_port,
  transport_options: [max_connections: :infinity, socket_opts: [:inet6]],
  otp_app: :cloudfire,
  keyfile: ssl_key_file,
  certfile: ssl_cert_file
]

https_opts = if ssl_ca_cert_file, do: base_opts ++ [cacertfile: ssl_ca_cert_file], else: base_opts

config :cf_http, CfHttpWeb.Endpoint,
  # Force SSL for releases
  https: https_opts,
  url: [host: url_host, port: https_listen_port],
  secret_key_base: secret_key_base,
  live_view: [
    signing_salt: live_view_signing_salt
  ]

config :cf_vpn,
  vpn_endpoint: wg_endpoint_address <> ":" <> wg_listen_port,
  private_key: Map.fetch!(config_file, "wg_server_key") |> String.trim()

# ## Using releases (Elixir v1.9+)
#
# If you are doing OTP releases, you need to instruct Phoenix
# to start each relevant endpoint:
#
config :cf_http, CfHttpWeb.Endpoint, server: true

config :cf_http, CfHttp.Vault,
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
      key: Base.decode64!(Map.fetch!(config_file, "db_encryption_key")),
      iv_length: 12
    }
  ]
