defmodule Domain.Auth.Adapters.TempAccount.Password do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string
    field :password_confirmation, :string, virtual: true, redact: true
  end
end
