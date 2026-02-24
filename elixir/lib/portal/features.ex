defmodule Portal.Features do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "features" do
    field :feature, Ecto.Enum, values: [:client_to_client]
    field :enabled, :boolean, default: false
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:feature, :enabled])
  end
end
