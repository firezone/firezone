defmodule FzHttp.MixProject do
  use Mix.Project

  def version do
    # Use dummy version for dev and test
    System.get_env("VERSION", "0.0.0+git.0.deadbeef")
  end

  def project do
    [
      app: :fz_http,
      version: version(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers(),
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

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {FzHttp.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :ueberauth_identity
      ],
      registered: [:fz_http_server]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:fz_common, in_umbrella: true},
      {:bypass, "~> 2.1", only: :test},
      {:decimal, "~> 2.0"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.2"},
      {:excoveralls, "~> 0.14", only: :test},
      {:floki, ">= 0.0.0", only: :test},
      {:mox, "~> 1.0.1", only: :test},
      {:guardian, "~> 2.0"},
      {:guardian_db, "~> 2.0"},
      # XXX: All github deps should use ref instead of always updating from master branch
      {:openid_connect, github: "firezone/openid_connect"},
      {:esaml, github: "firezone/esaml", override: true},
      {:samly, github: "firezone/samly"},
      {:ueberauth, "~> 0.7"},
      {:ueberauth_identity, "~> 0.4"},
      {:httpoison, "~> 1.8"},
      {:argon2_elixir, "~> 2.0"},
      {:phoenix_pubsub, "~> 2.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.7"},
      {:ecto_network,
       github: "firezone/ecto_network", ref: "7dfe65bcb6506fb0ed6050871b433f3f8b1c10cb"},
      {:inflex, "~> 2.1"},
      {:plug, "~> 1.13"},
      {:postgrex, "~> 0.16"},
      {:phoenix_html, "~> 3.2"},
      {:phoenix_live_view, "~> 0.18.3"},
      {:phoenix, "~> 1.7.0-rc.0", override: true},
      {:phoenix_live_dashboard, "~> 0.7.2"},
      {:phoenix_live_reload, "~> 1.3", only: :dev},
      {:gettext, "~> 0.18"},
      {:jason, "~> 1.2"},
      {:phoenix_swoosh, "~> 1.0"},
      {:gen_smtp, "~> 1.0"},
      {:nimble_totp, "~> 0.2"},
      # XXX: Change this when hex package is updated
      {:cidr, github: "firezone/cidr-elixir"},
      {:telemetry, "~> 1.0"},
      {:plug_cowboy, "~> 2.5"},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:remote_ip, "~> 1.0"},
      {:bureaucrat, "~> 0.2.9", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to create, migrate and run the seeds file at once:
  #
  #     $ mix ecto.setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      "ecto.seed": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end
