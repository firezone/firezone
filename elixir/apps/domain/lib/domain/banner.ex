defmodule Domain.Banner do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "banners" do
    field :message, :string
  end

  def changeset(changeset) do
    changeset
    |> validate_required([:message])
  end
end
