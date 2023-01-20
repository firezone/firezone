defmodule FzHttp.MFA.Method do
  use FzHttp, :schema

  schema "mfa_methods" do
    field :name, :string
    field :type, Ecto.Enum, values: [:totp, :native, :portable]
    field :last_used_at, :utc_datetime_usec
    field :payload, FzHttp.Encrypted.Map

    field :code, :string, virtual: true

    belongs_to :user, FzHttp.Users.User

    timestamps()
  end
end
