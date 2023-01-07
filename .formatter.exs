# Used by "mix format"
[
  locals_without_parens: [
    assert_authenticated: 2,
    assert_unauthenticated: 1
  ],
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
