defmodule FzHttp.Configurations.Configuration.OpenIDConnectProvider do
  @moduledoc """
  OIDC Config virtual schema
  """
  use FzHttp, :schema
  import Ecto.Changeset
  alias FzHttp.Validator

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
    # XXX: Store encrypted
    field :client_secret, :string
    field :discovery_document_uri, :string
    field :redirect_uri, :string
    field :auto_create_users, :boolean
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
    |> validate_discovery_document_uri()
    |> Validator.validate_uri([
      :redirect_uri
    ])
  end

  def validate_discovery_document_uri(changeset) do
    changeset
    |> validate_change(:discovery_document_uri, fn :discovery_document_uri, value ->
      case OpenIDConnect.update_documents(discovery_document_uri: value) do
        {:ok, _update_result} ->
          []

        {:error, :update_documents, reason} ->
          [discovery_document_uri: "is invalid. Reason: #{inspect(reason)}"]
      end
    end)
  end
end
