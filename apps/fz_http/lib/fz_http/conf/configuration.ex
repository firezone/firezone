defmodule FzHttp.Conf.Configuration do
  use Ecto.Schema
  import Ecto.Changeset

  schema "configurations" do
    field :logo, :map

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [:logo])
    |> validate_required([:logo])
  end
end
