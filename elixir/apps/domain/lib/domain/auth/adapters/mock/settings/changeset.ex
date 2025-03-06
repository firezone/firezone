defmodule Domain.Auth.Adapters.Mock.Settings.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.Mock.Settings

  @fields ~w[max_actors_per_group num_actors num_groups]a

  def changeset(%Settings{} = settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_required(@fields)
  end
end
