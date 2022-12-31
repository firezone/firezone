defmodule FzHttp.Configurations.Configuration.OpenIDConnectProvider do
  @moduledoc """
  OIDC Config virtual schema
  """
  use FzHttp, :schema
  import Ecto.Changeset
  alias FzHttp.Validators

  @reserved_config_ids [
    "identity",
    "saml",
    "magic_link"
  ]

  @primary_key false
  embedded_schema do
    field :id, :string
    field :label, :string
    field :scope, :string, default: "openid email profile"
    field :response_type, :string, default: "code"
    field :client_id, :string
    field :client_secret, :string
    field :discovery_document_uri, :string
    field :redirect_uri, :string
    field :auto_create_users, :boolean, default: true
  end

  def changeset(struct \\ %__MODULE__{}, data) do
    struct
    |> cast(
      data,
      [
        :id,
        :label,
        :scope,
        :response_type,
        :client_id,
        :client_secret,
        :discovery_document_uri,
        :auto_create_users,
        :redirect_uri
      ]
    )
    |> validate_required([
      :id,
      :label,
      :scope,
      :response_type,
      :client_id,
      :client_secret,
      :discovery_document_uri,
      :auto_create_users
    ])
    # Don't allow users to enter reserved config ids
    |> validate_exclusion(:id, @reserved_config_ids)
    |> Validators.OpenIDConnect.validate_discovery_document_uri()
    |> Validators.Common.validate_uri([
      :redirect_uri
    ])
  end
end
