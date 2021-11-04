defmodule FirezoneUmbrella.MixProject do
  @moduledoc """
  Welcome to the Firezone Elixir Umbrella Project
  """

  use Mix.Project

  require Logger

  # Omnibus has already built a nice way of generating this, so use it
  def version do
    case System.cmd(File.cwd!() <> "/scripts/semver.sh", []) do
      {result, 0} ->
        result |> String.trim()

      {_, _} ->
        Logger.warn("Could not get semver. Using dummy value of 0.0.0")
        "0.0.0"
    end
  end

  def project do
    [
      name: :firezone,
      apps_path: "apps",
      version: version(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      docs: [
        logo: "apps/fz_http/assets/static/images/logo.svg",
        extras: ["README.md", "SECURITY.md", "CONTRIBUTING.md"]
      ],
      deps: deps(),
      aliases: aliases(),
      default_release: :firezone,
      releases: [
        firezone: [
          include_executables_for: [:unix],
          validate_compile_env: false,
          applications: [
            fz_http: :permanent,
            fz_wall: :permanent,
            fz_vpn: :permanent
          ],
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
      {:ex_doc, "~> 0.24", only: :dev, runtime: false},
      {:excoveralls, "~> 0.14", only: :test},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      "ecto.seed": "run apps/fz_http/priv/repo/seeds.exs",
      "ecto.setup": ["ecto.create", "ecto.migrate", "ecto.seed"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      start: ["phx.server", "run --no-halt"]
    ]
  end
end
