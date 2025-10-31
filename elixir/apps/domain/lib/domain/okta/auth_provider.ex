defmodule Domain.Okta.AuthProvider do
  use Domain, :schema

  @fields ~w[
    name
    context
    okta_domain
    client_id
    client_secret
    issuer
    is_disabled
    is_default
    is_verified
  ]a

  @primary_key false
  schema "okta_auth_providers" do
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

    field :name, :string, default: "Okta"
    field :okta_domain, :string
    field :client_id, :string
    field :client_secret, :string, redact: true

    # Built from the okta_domain
    field :discovery_document_uri, :string, virtual: true

    subject_trail(~w[actor identity system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([
      :name,
      :context,
      :okta_domain,
      :client_id,
      :client_secret,
      :is_verified
    ])
    |> validate_acceptance(:is_verified)
    |> put_discovery_document_uri()
    |> validate_required(:discovery_document_uri)
    |> validate_uri(:discovery_document_uri)
    |> validate_length(:okta_domain, min: 1, max: 255)
    |> validate_fqdn(:okta_domain)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> validate_length(:client_id, min: 1, max: 255)
    |> validate_length(:client_secret, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:client_id,
      name: :okta_auth_providers_account_id_client_id_index,
      message: "An Okta authentication provider with this client_id already exists."
    )
    |> unique_constraint(:name,
      name: :okta_auth_providers_account_id_name_index,
      message: "An Okta authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> foreign_key_constraint(:account_id, name: :okta_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :okta_auth_providers_auth_provider_id_fkey
    )
  end

  def fields, do: @fields

  defp put_discovery_document_uri(changeset) do
    case get_field(changeset, :okta_domain) do
      nil ->
        changeset

      okta_domain ->
        uri = "https://#{okta_domain}/.well-known/openid-configuration"
        put_change(changeset, :discovery_document_uri, uri)
    end
  end
end
