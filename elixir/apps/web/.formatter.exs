[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{xml.heex,html.heex,ex,exs}",
    "{config,lib,test}/**/*.{xml.heex,html.heex,ex,exs}"
  ],
  locals_without_parens: [
    assert_authenticated: 2,
    assert_unauthenticated: 1,
    assert_lists_equal: 2
  ]
]
