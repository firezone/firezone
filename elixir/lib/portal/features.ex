defmodule Portal.Features do
  use Ecto.Schema

  @primary_key false

  schema "features" do
    field :feature, Ecto.Enum, values: [:client_to_client]
    field :enabled, :boolean, default: false
  end
end
