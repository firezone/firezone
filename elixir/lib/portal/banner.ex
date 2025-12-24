defmodule Portal.Banner do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "banners" do
    field :message, :string
  end

  def changeset(changeset_or_struct, attrs \\ %{}) do
    changeset_or_struct
    |> change(attrs)
    |> validate_required([:message])
  end
end
