defmodule Domain.OIDC.AuthProvider do
  use Domain, :schema

  @fields ~w[
    name
    context
    client_id
    client_secret
    discovery_document_uri
    issuer
    is_disabled
    is_default
    is_verified
  ]a

  @primary_key false
  schema "oidc_auth_providers" do
    # Allows setting the ID manually in changesets
    field :id, Ecto.UUID, primary_key: true

    belongs_to :account, Domain.Accounts.Account

    belongs_to :auth_provider, Domain.AuthProviders.AuthProvider,
      foreign_key: :id,
      define_field: false

    field :issuer, :string

    field :context, Ecto.Enum,
      values: ~w[clients_and_portal clients_only portal_only]a,
      default: :clients_and_portal

    field :is_verified, :boolean, virtual: true, default: true
    field :is_disabled, :boolean, read_after_writes: true, default: false
    field :is_default, :boolean, read_after_writes: true, default: false

    field :name, :string, default: "OpenID Connect"
    field :client_id, :string
    field :client_secret, :string, redact: true
    field :discovery_document_uri, :string

    subject_trail(~w[actor identity system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([
      :name,
      :context,
      :client_id,
      :client_secret,
      :discovery_document_uri,
      :issuer,
      :is_verified
    ])
    |> validate_acceptance(:is_verified)
    |> validate_length(:client_id, min: 1, max: 255)
    |> validate_length(:client_secret, min: 1, max: 255)
    |> validate_uri(:discovery_document_uri)
    |> validate_length(:discovery_document_uri, min: 1, max: 2000)
    |> validate_length(:issuer, min: 1, max: 2000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:client_id,
      name: :oidc_auth_providers_account_id_client_id_index,
      message: "An OIDC authentication provider with this client_id already exists."
    )
    |> unique_constraint(:name,
      name: :oidc_auth_providers_account_id_name_index,
      message: "An OIDC authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> foreign_key_constraint(:account_id, name: :oidc_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :oidc_auth_providers_auth_provider_id_fkey
    )
  end

  def fields, do: @fields
end
