defmodule FzVpn.MixProject do
  use Mix.Project

  @version_path "../../scripts/version.exs"

  def version do
    Code.eval_file(@version_path)
    |> elem(0)
  end

  def project do
    [
      app: :fz_vpn,
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
      mod: {FzVpn.Application, []},
      registered: [:fz_vpn_server]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fz_http, in_umbrella: true},
      {:fz_common, in_umbrella: true},
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.13", only: :test}
    ]
  end
end
