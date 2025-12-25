[
  import_deps: [
    :ecto,
    :open_api_spex,
    :phoenix,
    :phoenix_live_view,
    :plug
  ],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{ex,exs}",
    "{.credo,config,lib,test,priv}/**/*.{ex,exs,heex,xml.heex,html.heex}"
  ],
  locals_without_parens: [
    assert_authenticated: 2,
    assert_unauthenticated: 1,
    assert_lists_equal: 2
  ]
]
