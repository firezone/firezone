defmodule Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :web,
      version: version(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      listeners: [Phoenix.CodeReloader],
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
      mod: {Web.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :dialyzer
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella deps
      {:domain, in_umbrella: true},

      # Phoenix/Plug deps
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:plug_cowboy, "~> 2.7"},
      {:gettext, "~> 0.20"},
      {:remote_ip, "~> 1.0"},

      # Unit conversions
      {:tzdata, "~> 1.1"},
      {:sizeable, "~> 1.0"},

      # Asset pipeline deps
      {:esbuild, "~> 0.7", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3.1", runtime: Mix.env() == :dev},

      # Observability and debugging deps
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:recon, "~> 2.5"},
      {:observer_cli, "~> 1.7"},

      # Observability
      {:opentelemetry_telemetry, "~> 1.1", override: true},
      {:opentelemetry_cowboy, "~> 1.0"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:nimble_options, "~> 1.0", override: true},
      {:sentry, "~> 11.0"},
      {:hackney, "~> 1.19"},
      {:logger_json, "~> 7.0"},

      # Test deps
      {:floki, "~> 0.38.0", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:wallaby, "~> 0.30.0", only: :test},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:junit_formatter, "~> 3.3", only: [:test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:sobelow, "~> 0.12", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": [
        "cmd cd assets && CI=true pnpm i",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["tailwind web", "esbuild web"],
      "assets.deploy": ["tailwind web --minify", "esbuild web --minify", "phx.digest"],
      "ecto.seed": ["ecto.create", "ecto.migrate", "run ../domain/priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "phx.server": ["ecto.create --quiet", "ecto.migrate", "phx.server"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end

  defp version do
    sha = System.get_env("GIT_SHA", "dev") |> String.trim()
    "0.1.0+#{sha}"
  end
end
