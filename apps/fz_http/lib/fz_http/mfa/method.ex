defmodule FzHttp.MFA.Method do
  @moduledoc """
  Multi Factor Authentication methods
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "mfa_methods" do
    field :name, :string
    field :type, Ecto.Enum, values: [:totp, :native, :portable]
    field :credential_id, :string
    field :last_used_at, :utc_datetime_usec
    field :payload, FzHttp.Encrypted.Map
    field :user_id, :id
    field :secret, :string, virtual: true
    field :code, :string, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(method, attrs) do
    method
    |> cast(attrs, [:name, :type, :credential_id, :payload, :last_used_at, :secret, :code])
    |> cast_payload()
    |> validate_required([:name, :type, :payload])
    |> validate_code()
  end

  defp cast_payload(%{changes: %{secret: secret}} = changeset) do
    put_change(changeset, :payload, %{secret: secret})
  end

  defp cast_payload(changeset), do: changeset

  defp validate_code(%{changes: %{code: code, secret: secret}} = changeset) do
    if NimbleTOTP.verification_code(Base.decode64!(secret)) == code do
      changeset
    else
      add_error(changeset, :code, "is not valid")
    end
  end

  defp validate_code(changeset), do: changeset
end
