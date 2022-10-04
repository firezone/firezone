defmodule FzHttp.Conf.Logo do
  @moduledoc """
  Embedded Schema for logo
  """

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :url, :string
    field :data, :string
    field :type, :string
  end

  def changeset(logo, attrs) do
    logo
    |> cast(attrs, [
      :url,
      :data,
      :type
    ])
  end
end
