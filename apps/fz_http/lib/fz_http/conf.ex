defmodule FzHttp.Conf do
  @moduledoc """
  The Conf context for app configurations.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{Repo, Conf.Configuration}

  def get_configuration! do
    Repo.one!(Configuration)
  end

  def change_configuration(%Configuration{} = config) do
    Configuration.changeset(config, %{})
  end

  def update_configuration(%Configuration{} = config, attrs) do
    config
    |> Configuration.changeset(attrs)
    |> Repo.update()
  end
end
