defmodule FzHttp.Conf.Configuration do
  use Ecto.Schema
  import Ecto.Changeset

  schema "configurations" do
    field :name, :string
    field :logo, :map

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [:name, :logo])
    |> validate_required([:name, :logo])
  end
end
