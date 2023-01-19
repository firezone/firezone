defmodule FzCommon.MixProject do
  use Mix.Project

  def version do
    # Use dummy version for dev and test
    System.get_env("VERSION", "0.0.0+git.0.deadbeef")
  end

  def project do
    [
      app: :fz_common,
      version: version(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:file_size, "~> 3.0.1"},
      {:posthog, "~> 0.1"},
      {:jason, "~> 1.2"},
      {:cidr, github: "firezone/cidr-elixir"},
      {:ecto_network,
       github: "firezone/ecto_network", ref: "7dfe65bcb6506fb0ed6050871b433f3f8b1c10cb"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      # {:sibling_app_in_umbrella, in_umbrella: true}
    ]
  end
end
