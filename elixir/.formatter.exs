[
  plugins: [Phoenix.LiveView.HTMLFormatter],
  subdirectories: ["apps/*"],
  # Prevents attr and slot etc from being formatted
  import_deps: [:phoenix, :phoenix_html, :phoenix_live_view],
  inputs: [
    "*.{ex,exs}",
    "{config,priv}/**/*.{ex,exs}"
  ]
]
