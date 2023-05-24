defmodule Domain.Auth.Adapters.Token.State do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :secret_hash, :string, redact: true
    field :expires_at, :utc_datetime_usec
  end
end
