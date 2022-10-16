defmodule FzHttp.Conf.SAMLConfig do
  @moduledoc """
  SAML Config virtual schema
  """
  use Ecto.Schema

  import Ecto.Changeset
  import FzHttp.Validators.SAML

  @primary_key false
  embedded_schema do
    field :id, :string
    field :label, :string
    field :metadata, :string
    field :auto_create_users, :boolean, default: true
  end

  def changeset(data) do
    %__MODULE__{}
    |> cast(data, [:id, :label, :metadata, :auto_create_users])
    |> validate_required([:id, :label, :metadata, :auto_create_users])
    |> validate_metadata()
  end
end
