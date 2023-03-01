[
  locals_without_parens: [
    assert_authenticated: 2,
    assert_unauthenticated: 1,
    defperm: 2
  ],
  import_deps: [
    :ecto,
    :phoenix,
    :phoenix_live_view
  ],
  inputs: [
    "*.{heex,ex,exs}",
    "{lib,test,priv}/**/*.{heex,ex,exs}"
  ],
  plugins: [
    Phoenix.LiveView.HTMLFormatter
  ]
]
