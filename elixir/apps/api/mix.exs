defmodule API.MixProject do
  use Mix.Project

  def project do
    [
      app: :api,
      version: String.trim(File.read!("../../VERSION")),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {API.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella deps
      {:domain, in_umbrella: true},

      # Phoenix deps
      {:phoenix, "~> 1.7.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:plug_cowboy, "~> 2.7"},

      # Observability deps
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:opentelemetry_cowboy, "~> 0.2.1"},
      {:opentelemetry_phoenix, "~> 1.1"},

      # Other deps
      {:jason, "~> 1.2"},
      {:remote_ip, "~> 1.1"},

      # Test deps
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:junit_formatter, "~> 3.3", only: [:test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:sobelow, "~> 0.12", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      "ecto.seed": ["ecto.create", "ecto.migrate", "run ../domain/priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end
