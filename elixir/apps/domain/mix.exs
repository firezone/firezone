defmodule Domain.MixProject do
  use Mix.Project

  def project do
    [
      app: :domain,
      version: version(),
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
      {:postgrex, "~> 0.20"},
      {:decimal, "~> 2.0"},
      {:ecto_sql, "~> 3.7"},

      # PubSub and Presence
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.0"},

      # Auth-related deps
      {:plug_crypto, "~> 2.0"},
      {:jose, "~> 1.11"},
      {:openid_connect,
       github: "firezone/openid_connect", ref: "78d8650bc75a462a2ff193dd1bffb70e1cafe839"},
      {:argon2_elixir, "~> 4.0"},

      # Job system
      {:oban, "~> 2.19"},

      # Erlang Clustering
      {:libcluster, "~> 3.3"},

      # CLDR and unit conversions
      {:ex_cldr_dates_times, "~> 2.13"},
      {:ex_cldr_numbers, "~> 2.31"},
      {:ex_cldr, "~> 2.38"},

      # Mailer deps
      {:gen_smtp, "~> 1.0"},
      {:multipart, "~> 0.4.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_swoosh, "~> 1.0"},
      {:phoenix_template, "~> 1.0.4"},

      # Observability and Runtime debugging
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.15"},
      {:telemetry, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:recon, "~> 2.5"},
      {:observer_cli, "~> 1.7"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_logger_metadata, "~> 0.2.0"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_finch, "~> 0.2.0"},
      {:sentry, "~> 11.0"},
      {:hackney, "~> 1.19"},
      {:logger_json, "~> 7.0"},
      {:req, "~> 0.5.15"},

      # Other application deps
      {:tzdata, "~> 1.1"},

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

  defp version do
    sha = System.get_env("GIT_SHA", "dev") |> String.trim()
    "0.1.0+#{sha}"
  end
end
