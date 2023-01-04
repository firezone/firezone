defmodule FzHttp.Users.User do
  use FzHttp, :schema

  schema "users" do
    field :role, Ecto.Enum, values: [:unprivileged, :admin], default: :unprivileged
    field :email, :string
    field :password_hash, :string

    field :last_signed_in_at, :utc_datetime_usec
    field :last_signed_in_method, :string

    field :sign_in_token, :string, virtual: true, redact: true
    field :sign_in_token_hash, :string
    field :sign_in_token_created_at, :utc_datetime_usec

    # Virtual fields
    field :current_password, :string, virtual: true, redact: true
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true

    # Virtual fields that can be hydrated
    field :device_count, :integer, virtual: true

    has_many :devices, FzHttp.Devices.Device
    has_many :oidc_connections, FzHttp.OIDC.Connection
    has_many :api_tokens, FzHttp.ApiTokens.ApiToken

    field :disabled_at, :utc_datetime_usec
    timestamps()
  end
end
