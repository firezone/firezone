defmodule FzHttp.Conf.SAMLConfig do
  @moduledoc """
  SAML Config virtual schema
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :id, :string
    field :label, :string
    field :metadata, :string
  end

  def changeset(data) do
    %__MODULE__{}
    |> cast(data, [:id, :label, :metadata])
    |> validate_required([:id, :label, :metadata])
  end
end
