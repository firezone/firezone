defmodule FzWall.MixProject do
  use Mix.Project

  def version do
    # Use dummy version for dev and test
    System.get_env("VERSION", "0.0.0+git.0.deadbeef")
  end

  def project do
    [
      app: :fz_wall,
      version: version(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {FzWall.Application, []},
      registered: [:fz_wall_server]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fz_http, in_umbrella: true},
      {:cidr, github: "firezone/cidr-elixir"}
    ]
  end
end
