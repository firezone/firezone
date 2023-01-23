defmodule FzHttp.Configurations.Logo do
  @moduledoc """
  Embedded Schema for logo
  """
  use FzHttp, :schema
  import Ecto.Changeset

  # Singleton per configuration
  @primary_key false
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
