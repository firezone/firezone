defmodule FzHttp.MFA.Method do
  @moduledoc """
  Multi Factor Authentication methods
  """

  use Ecto.Schema
  import Ecto.Changeset
  import FzHttp.Validators.Common, only: [trim: 2]

  @primary_key {:id, :binary_id, autogenerate: true}
  @whitespace_trimmed_fields :name

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
    |> trim(@whitespace_trimmed_fields)
    |> cast_payload()
    |> validate_required([:name, :type, :payload])
    |> validate_code()
  end

  defp cast_payload(%{changes: %{secret: secret}} = changeset) do
    put_change(changeset, :payload, %{"secret" => secret})
  end

  defp cast_payload(changeset), do: changeset

  defp validate_code(%{changes: %{code: code}} = changeset) do
    secret = Base.decode64!(fetch_field!(changeset, :payload)["secret"])

    if NimbleTOTP.valid?(secret, code, since: fetch_field!(changeset, :last_used_at)) do
      put_change(changeset, :last_used_at, DateTime.utc_now())
    else
      add_error(changeset, :code, "is not valid")
    end
  end

  defp validate_code(changeset), do: changeset
end
