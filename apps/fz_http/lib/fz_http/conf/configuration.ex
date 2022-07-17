defmodule FzHttp.Conf.Configuration do
  @moduledoc """
  App global configuration, singleton resource
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "configurations" do
    field :logo, :map

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [:logo])
  end
end
