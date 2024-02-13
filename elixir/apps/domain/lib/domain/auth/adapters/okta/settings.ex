defmodule Domain.Auth.Adapters.Okta.Settings do
  use Domain, :schema

  @scope ~w[
    openid email profile
    offline_access
    okta.groups.read
    okta.users.read
  ]

  @primary_key false
  embedded_schema do
    field :scope, :string, default: Enum.join(@scope, " ")
    field :response_type, :string, default: "code"
    field :client_id, :string
    field :client_secret, :string
    field :discovery_document_uri, :string
    field :oauth_uri, :string
    field :api_base_url, :string
  end

  def scope, do: @scope
end
