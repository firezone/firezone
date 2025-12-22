defmodule Firezone.MixProject do
  use Mix.Project

  def project do
    [
      name: :firezone,
      apps_path: "apps",
      version: version(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      listeners: listeners(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      docs: [
        logo: "apps/web/assets/static/images/logo.svg",
        extras: ["docs/README.md", "docs/SECURITY.md", "docs/CONTRIBUTING.md"]
      ],
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ],
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp listeners do
    # Dependabot complains about this dependency missing during its check - so only load it conditionally
    if Code.ensure_loaded?(Phoenix.CodeReloader) do
      [Phoenix.CodeReloader]
    else
      []
    end
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      # Shared deps
      {:sentry, "~> 11.0"},
      {:hackney, "~> 1.19"},
      {:logger_json, "~> 7.0"},
      {:req, "~> 0.5.15"},

      # Shared test deps
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:junit_formatter, "~> 3.3", only: [:test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:sobelow, "~> 0.12", only: [:dev, :test]},

      # Formatter doesn't track dependencies of children applications
      {:phoenix, "~> 1.8.1"},
      {:phoenix_live_view, "~> 1.1.8"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:floki, "~> 0.38.0"}
    ]
  end

  defp aliases do
    migration_args =
      "--migrations-path apps/domain/priv/repo/migrations --migrations-path apps/domain/priv/repo/manual_migrations"

    [
      "ecto.migrate": ["ecto.migrate #{migration_args}"],
      "ecto.rollback": ["ecto.rollback #{migration_args}"],
      "ecto.seed": [
        "ecto.create",
        "ecto.migrate #{migration_args}",
        "run apps/domain/priv/repo/seeds.exs"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      reboot: ["ecto.reset", "run apps/domain/priv/repo/seeds.exs", "start"],
      sobelow: ["cmd mix sobelow"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      start: ["compile --no-validate-compile-env", "phx.server", "run --no-halt"]
    ]
  end

  defp releases do
    [
      domain: [
        include_executables_for: [:unix],
        validate_compile_env: true,
        applications: [
          domain: :permanent,
          opentelemetry_exporter: :permanent,
          opentelemetry: :temporary
        ]
      ],
      web: [
        include_executables_for: [:unix],
        validate_compile_env: true,
        applications: [
          web: :permanent,
          opentelemetry_exporter: :permanent,
          opentelemetry: :temporary
        ]
      ],
      api: [
        include_executables_for: [:unix],
        validate_compile_env: true,
        applications: [
          api: :permanent,
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
