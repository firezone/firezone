defmodule Domain.Auth.Adapters.JumpCloud.Settings do
  use Domain, :schema

  @scope ~w[
    openid email profile
  ]

  @discovery_document_uri "https://oauth.id.jumpcloud.com/.well-known/openid-configuration"

  @primary_key false
  embedded_schema do
    field :scope, :string, default: Enum.join(@scope, " ")
    field :response_type, :string, default: "code"
    field :client_id, :string
    field :client_secret, :string
    field :discovery_document_uri, :string, default: @discovery_document_uri
    field :api_key, :string
  end

  def scope, do: @scope
end
