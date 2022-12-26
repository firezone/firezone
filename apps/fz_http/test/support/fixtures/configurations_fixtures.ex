defmodule FzHttp.ConfigurationsFixtures do
  @moduledoc """
  Allows for easily updating configuration in tests.
  """

  alias FzHttp.{
    Configurations,
    Configurations.Configuration,
    Repo
  }

  @doc "Configurations table holds a singleton record."
  def configuration(%Configuration{} = conf \\ Configurations.get_configuration!(), attrs) do
    {:ok, configuration} =
      conf
      |> Configuration.changeset(attrs)
      |> Repo.update()

    configuration
  end
end
