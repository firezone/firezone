defmodule Portal.Banner do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false

  schema "banners" do
    field :message, :string

    field :color, Ecto.Enum,
      values: [:warning, :info, :error, :success, :announcement],
      default: :warning
  end
end
