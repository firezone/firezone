defmodule Domain.Auth.Adapters.GoogleWorkspace.Settings do
  use Domain, :schema

  @scope ~w[
    openid email profile
    https://www.googleapis.com/auth/admin.directory.customer.readonly
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

    embeds_one :service_account_json_key, GoogleServiceAccountKey,
      primary_key: false,
      on_replace: :update do
      field :type, :string
      field :project_id, :string

      field :private_key_id, :string
      field :private_key, :string

      field :client_email, :string
      field :client_id, :string

      field :auth_uri, :string
      field :token_uri, :string
      field :auth_provider_x509_cert_url, :string
      field :client_x509_cert_url, :string

      field :universe_domain, :string
    end
  end

  def scope, do: @scope
end
