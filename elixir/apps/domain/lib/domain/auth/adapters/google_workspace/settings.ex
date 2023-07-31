defmodule Domain.Auth.Adapters.GoogleWorkspace.Settings do
  use Domain, :schema

  @scope ~w[
    openid email profile
    https://www.googleapis.com/auth/admin.directory.orgunit.readonly
    https://www.googleapis.com/auth/admin.directory.group.readonly
    https://www.googleapis.com/auth/admin.directory.user.readonly
  ]

  @discovery_document_uri "https://accounts.google.com/.well-known/openid-configuration"

  @primary_key false
  embedded_schema do
    field :scope, :string, default: Enum.join(@scope, " ")
    field :response_type, :string, default: "code"
    field :client_id, :string
    field :client_secret, :string
    field :discovery_document_uri, :string, default: @discovery_document_uri
  end
end

# field :provisioners, Ecto.Enum, values: [:manual, :just_in_time, :custom]
