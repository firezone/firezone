import Config

config :fz_http, FzHttpWeb.Endpoint,
  http: [port: 13000],
  debug_errors: true,
  code_reloader: true,
  check_origin: ["//127.0.0.1", "//localhost"],
  watchers: [
    node: ["esbuild.js", "dev", cd: Path.expand("../apps/fz_http/assets", __DIR__)]
  ],
  live_reload: [
    patterns: [
      ~r"apps/fz_http/priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/fz_http/priv/gettext/.*(po)$",
      ~r"apps/fz_http/lib/fz_http_web/(live|views)/.*(ex)$",
      ~r"apps/fz_http/lib/fz_http_web/templates/.*(eex)$"
    ]
  ]

###############################
##### FZ Firewall configs #####
###############################

get_egress_interface = fn ->
  egress_interface_cmd =
    case :os.type() do
      {:unix, :darwin} -> "netstat -rn -finet | grep '^default' | awk '{print $NF;}'"
      {_os_family, _os_name} -> "route | grep '^default' | grep -o '[^ ]*$'"
    end

  System.cmd("/bin/sh", ["-c", egress_interface_cmd], stderr_to_stdout: true)
  |> elem(0)
  |> String.trim()
end

egress_interface = System.get_env("EGRESS_INTERFACE") || get_egress_interface.()

{fz_wall_cli_module, _} =
  Code.eval_string(System.get_env("FZ_WALL_CLI_MODULE", "FzWall.CLI.Sandbox"))

config :fz_wall,
  nft_path: System.get_env("NFT_PATH", "nft"),
  egress_interface: egress_interface,
  cli: fz_wall_cli_module

###############################
##### FZ VPN configs ##########
###############################

config :fz_vpn,
  supervised_children: [FzVpn.Interface.WGAdapter.Sandbox, FzVpn.Server, FzVpn.StatsPushService]

###############################
##### Third-party configs #####
###############################

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :fz_http, FzHttpWeb.Mailer, adapter: Swoosh.Adapters.Local
