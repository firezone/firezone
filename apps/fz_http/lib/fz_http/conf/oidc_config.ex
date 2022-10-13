defmodule FzHttp.Conf.OIDCConfig do
  @moduledoc """
  OIDC Config virtual schema
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :id, :string
    field :label, :string
    field :scope, :string, default: "openid email profile"
    field :response_type, :string, default: "code"
    field :client_id, :string
    field :client_secret, :string
    field :discovery_document_uri, :string
    field :auto_create_users, :boolean
  end

  def changeset(data) do
    %__MODULE__{}
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
        :auto_create_users
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
  end
end
