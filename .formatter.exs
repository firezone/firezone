# Used by "mix format"
[
  import_deps: [
    :ecto,
    :phoenix
  ],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,apps,priv}/**/*.{heex,ex,exs}"
  ],
  plugins: [
    Phoenix.LiveView.HTMLFormatter
  ]
]
