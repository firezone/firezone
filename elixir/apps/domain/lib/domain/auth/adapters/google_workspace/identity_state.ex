defmodule Domain.Auth.Adapters.GoogleWorkspace.IdentityState do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :access_token, Domain.Types.EncryptedString
    field :refresh_token, Domain.Types.EncryptedString

    field :userinfo, :map
    field :claims, :map

    field :expires_at, :utc_datetime_usec
  end
end
