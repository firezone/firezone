defmodule API.MixProject do
  use Mix.Project

  def project do
    [
      app: :api,
      version: version(),
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
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.4"},
      {:plug_cowboy, "~> 2.7"},

      # Observability deps
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:opentelemetry_telemetry, "~> 1.1.1", override: true},
      {:opentelemetry_cowboy, "~> 1.0"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:sentry, "~> 11.0"},
      {:hackney, "~> 1.19"},
      {:logger_json, "~> 7.0"},

      # Other deps
      {:remote_ip, "~> 1.1"},
      {:open_api_spex, "~> 3.22.0"},
      {:ymlr, "~> 5.0"},
      {:hammer, "~> 7.1.0"},

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

  defp version do
    sha = System.get_env("GIT_SHA", "dev") |> String.trim()
    "0.1.0+#{sha}"
  end
end
