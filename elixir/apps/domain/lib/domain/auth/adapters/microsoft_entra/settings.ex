defmodule Domain.Auth.Adapters.MicrosoftEntra.Settings do
  use Domain, :schema

  @scope ~w[
    openid email profile
    offline_access
    Group.Read.All
    GroupMember.Read.All
    User.Read
    User.Read.All
  ]

  @primary_key false
  embedded_schema do
    field :scope, :string, default: Enum.join(@scope, " ")
    field :response_type, :string, default: "code"
    field :client_id, :string
    field :client_secret, :string
    field :discovery_document_uri, :string
  end

  def scope, do: @scope
end
