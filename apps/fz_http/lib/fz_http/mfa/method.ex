defmodule FzHttp.MFA.Method do
  @moduledoc """
  Multi Factor Authentication methods
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "mfa_methods" do
    field :name, :string
    field :type, :string
    field :credential_id, :string
    field :last_used_at, :utc_datetime_usec
    field :payload, FzHttp.Encrypted.Map
    field :user_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(method, attrs) do
    method
    |> cast(attrs, [:name, :type, :credential_id, :payload, :last_used_at])
    |> validate_required([:name, :type, :payload])
  end
end
