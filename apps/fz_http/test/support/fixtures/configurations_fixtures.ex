defmodule FzHttp.ConfigurationsFixtures do
  @moduledoc """
  Allows for easily updating configuration in tests.
  """

  alias FzHttp.{
    Configurations,
    Configurations.Configuration,
    Repo
  }

  def update_conf(%Configuration{} = conf \\ Configurations.get_configuration!(), attrs) do
    conf
    |> Configuration.changeset(attrs)
    |> Repo.update()
  end
end
