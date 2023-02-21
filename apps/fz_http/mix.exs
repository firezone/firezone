defmodule FzHttp.MixProject do
  use Mix.Project

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

  def version do
    # Use dummy version for dev and test
    System.get_env("VERSION", "0.0.0+git.0.deadbeef")
  end

  def application do
    [
      mod: {FzHttp.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["test/support", "lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella deps
      {:fz_common, in_umbrella: true},

      # Phoenix/Plug deps
      {:plug, "~> 1.13"},
      {:plug_cowboy, "~> 2.5"},
      {:phoenix, "~> 1.7.0-rc.2", override: true},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 3.2"},
      {:phoenix_pubsub, "~> 2.0"},
      {:phoenix_live_view, "~> 0.18.8"},
      {:phoenix_live_dashboard, "~> 0.7.2"},
      {:phoenix_live_reload, "~> 1.3", only: :dev},
      {:phoenix_swoosh, "~> 1.0"},
      {:gettext, "~> 0.18"},
      {:file_size, "~> 3.0.1"},

      # Ecto-related deps
      {:postgrex, "~> 0.16"},
      {:decimal, "~> 2.0"},
      {:ecto_sql, "~> 3.7"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.2"},

      # Auth-related deps
      {:guardian, "~> 2.0"},
      {:guardian_db, "~> 2.0"},
      {:openid_connect, github: "firezone/openid_connect", branch: "andrew/rewrite"},
      # XXX: All github deps should use ref instead of always updating from master branch
      {:esaml, github: "firezone/esaml", override: true},
      {:samly, github: "firezone/samly"},
      {:ueberauth, "~> 0.7"},
      {:ueberauth_identity, "~> 0.4"},
      {:argon2_elixir, "~> 2.0"},
      {:nimble_totp, "~> 0.2"},

      # Other deps
      {:remote_ip, "~> 1.0"},
      # XXX: Drop it, it's not maintained anymore
      {:httpoison, "~> 1.8"},
      # XXX: Change this when hex package is updated
      {:cidr, github: "firezone/cidr-elixir"},
      {:telemetry, "~> 1.0"},
      # Used in Swoosh SMTP adapter
      {:gen_smtp, "~> 1.0"},

      # Test and dev deps
      {:bypass, "~> 2.1", only: :test},
      {:wallaby, "~> 0.30.0", only: :test},
      {:bureaucrat, "~> 0.2.9", only: :test},
      {:floki, "~> 0.34.0"}
    ]
  end

  defp aliases do
    [
      "assets.build": ["cmd cd assets && yarn install --frozen-lockfile && node esbuild.js prod"],
      "ecto.seed": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end
