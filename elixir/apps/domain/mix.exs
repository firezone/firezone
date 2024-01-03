defmodule Domain.MixProject do
  use Mix.Project

  def project do
    [
      app: :domain,
      version: String.trim(File.read!("../../VERSION")),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.12",
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
      mod: {Domain.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :crypto,
        :dialyzer
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["test/support", "lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Ecto-related deps
      {:postgrex, "~> 0.16"},
      {:decimal, "~> 2.0"},
      {:ecto_sql, "~> 3.7"},

      # PubSub and Presence
      {:phoenix, "~> 1.7", runtime: false},
      {:phoenix_pubsub, "~> 2.0"},

      # Auth-related deps
      {:plug_crypto, "~> 2.0"},
      {:openid_connect, github: "firezone/openid_connect", branch: "master"},
      {:argon2_elixir, "~> 4.0"},

      # Erlang Clustering
      {:libcluster, "~> 3.3"},

      # Observability and Runtime debugging
      {:telemetry, "~> 1.0"},
      {:logger_json, "~> 5.1"},
      {:recon, "~> 2.5"},
      {:observer_cli, "~> 1.7"},
      {:opentelemetry, "~> 1.3"},
      {:opentelemetry_logger_metadata, "~> 0.1.0"},
      {:opentelemetry_exporter, "~> 1.5"},
      {:opentelemetry_ecto, "~> 1.1"},
      {:opentelemetry_finch, "~> 0.2.0"},

      # Mailer deps
      # XXX: This is a workaround for the following issue:
      # https://github.com/elixir-lang/elixir/issues/12777
      # Remove Swoosh from Domain once this is fixed.
      {:phoenix_swoosh, "~> 1.0"},
      {:hackney, "~> 1.9"},

      # Test and dev deps
      {:bypass, "~> 2.1", only: :test},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:junit_formatter, "~> 3.3", only: [:test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:sobelow, "~> 0.12", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      "ecto.seed": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end
