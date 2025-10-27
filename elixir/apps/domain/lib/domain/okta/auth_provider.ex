defmodule Domain.Okta.AuthProvider do
  use Domain, :schema

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

    field :disabled_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :assigned_default_at, :utc_datetime_usec

    field :name, :string, default: "Okta"
    field :org_domain, :string
    field :client_id, :string
    field :client_secret, :string, redact: true

    # Built from the org_domain
    field :discovery_document_uri, :string, virtual: true

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
