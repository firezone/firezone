defmodule FireguardUmbrella.MixProject do
  @moduledoc """
  Welcome to the FireGuard Elixir Umbrella Project
  """

  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.7",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      deps: deps(),
      aliases: aliases(),
      default_release: :fireguard,
      releases: [
        fireguard: [
          # Don't seem to be needed for bakeware releases
          # include_executables_for: [:unix],
          # validate_compile_env: false,
          applications: [
            fg_http: :permanent,
            fg_wall: :permanent,
            fg_vpn: :permanent
          ],
          steps: [:assemble, &Bakeware.assemble/1],
          cookie: System.get_env("ERL_COOKIE")
        ]
      ]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:bakeware, "~> 0.2.0", runtime: false},
      {:excoveralls, "~> 0.13", only: :test},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      start: ["phx.server", "run --no-halt"]
    ]
  end
end
