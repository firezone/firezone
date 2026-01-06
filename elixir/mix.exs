defmodule Portal.MixProject do
  use Mix.Project

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def project do
    [
      app: :portal,
      version: version(),
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      listeners: [Phoenix.CodeReloader],
      docs: [
        logo: "assets/static/images/logo.svg",
        extras: ["docs/README.md", "docs/SECURITY.md", "docs/CONTRIBUTING.md"]
      ],
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :credo]
      ],
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {Portal.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :crypto,
        :dialyzer
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", ".credo"]
  defp elixirc_paths(:dev), do: ["lib", ".credo"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Ecto / Database
      {:postgrex, "~> 0.20"},
      {:decimal, "~> 2.0"},
      {:ecto_sql, "~> 3.7"},
      {:phoenix_ecto, "~> 4.4"},

      # Phoenix / Plug
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_template, "~> 1.0.4"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.15"},
      {:gettext, "~> 0.20"},
      {:remote_ip, "~> 1.1"},

      # Auth
      {:plug_crypto, "~> 2.0"},
      {:jose, "~> 1.11"},
      {:openid_connect,
       github: "firezone/openid_connect", ref: "78d8650bc75a462a2ff193dd1bffb70e1cafe839"},
      {:argon2_elixir, "~> 4.0"},

      # Background jobs
      {:oban, "~> 2.19"},

      # Erlang clustering
      {:libcluster, "~> 3.3"},

      # CLDR / Internationalization
      {:ex_cldr_dates_times, "~> 2.13"},
      {:ex_cldr_numbers, "~> 2.31"},
      {:ex_cldr, "~> 2.38"},
      {:tzdata, "~> 1.1"},
      {:sizeable, "~> 1.0"},

      # Email
      {:gen_smtp, "~> 1.0"},
      {:multipart, "~> 0.4.0"},
      {:phoenix_swoosh, "~> 1.0"},

      # API / OpenAPI
      {:open_api_spex, "~> 3.22.0"},
      {:ymlr, "~> 5.0"},
      {:hammer, "~> 7.1.0"},

      # Observability
      {:telemetry, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:recon, "~> 2.5"},
      {:observer_cli, "~> 1.7"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_logger_metadata, "~> 0.2.0"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_telemetry, "~> 1.1", override: true},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:nimble_options, "~> 1.0", override: true},
      {:sentry, "~> 11.0"},
      {:hackney, "~> 1.19"},
      {:logger_json, "~> 7.0"},
      {:req, "~> 0.5.15"},

      # Asset pipeline
      {:esbuild, "~> 0.7", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4.1", runtime: Mix.env() == :dev},

      # Test deps
      {:bypass, "~> 2.1", only: :test},
      {:wallaby, "~> 0.30.0", only: :test},
      {:floki, "~> 0.38.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:junit_formatter, "~> 3.3", only: :test},

      # Dev/test deps
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:sobelow, "~> 0.12", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.migrate": [
        "ecto.migrate --migrations-path priv/repo/migrations --migrations-path priv/repo/manual_migrations"
      ],
      "ecto.rollback": [
        "ecto.rollback --migrations-path priv/repo/migrations --migrations-path priv/repo/manual_migrations"
      ],
      "ecto.seed": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      reboot: ["ecto.reset", "run priv/repo/seeds.exs", "start"],
      sobelow: ["sobelow --config"],
      "assets.setup": [
        "cmd --shell cd assets && CI=true pnpm i",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["tailwind portal", "esbuild portal"],
      "assets.deploy": ["tailwind portal --minify", "esbuild portal --minify", "phx.digest"],
      "phx.server": ["ecto.create --quiet", "ecto.migrate", "phx.server"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      start: ["compile --no-validate-compile-env", "phx.server", "run --no-halt"]
    ]
  end

  defp releases do
    [
      portal: [
        include_executables_for: [:unix],
        validate_compile_env: true,
        applications: [
          portal: :permanent,
          opentelemetry_exporter: :permanent,
          opentelemetry: :temporary
        ]
      ]
    ]
  end

  defp version do
    sha = System.get_env("GIT_SHA", "dev") |> String.trim()
    "0.1.0+#{sha}"
  end
end
