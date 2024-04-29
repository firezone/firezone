defmodule Domain.Auth.Adapters.OpenIDConnect.ProviderConfig do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :scope, :string, default: "openid email profile"
    field :response_type, :string, default: "code"
    field :client_id, :string
    field :client_secret, Domain.Types.EncryptedString
    field :discovery_document_uri, :string
  end
end
