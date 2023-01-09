# Used by "mix format"
[
  import_deps: [
    :ecto,
    :phoenix
  ],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,priv}/**/*.{heex,ex,exs}",
    "apps/{fz_vpn,fz_wall}/**/*.{heex,ex,exs}",
    "apps/fz_http/*.exs",
    "apps/fz_http/{lib,test,priv}/**/*.{heex,ex,exs}"
  ],
  plugins: [
    Phoenix.LiveView.HTMLFormatter
  ]
]
