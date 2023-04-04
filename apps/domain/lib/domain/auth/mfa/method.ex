defmodule Domain.Auth.MFA.Method do
  use Domain, :schema

  schema "mfa_methods" do
    field :name, :string
    field :type, Ecto.Enum, values: [:totp, :native, :portable]
    field :last_used_at, :utc_datetime_usec
    field :payload, Domain.Encrypted.Map

    field :code, :string, virtual: true

    belongs_to :user, Domain.Users.User

    timestamps()
  end
end
