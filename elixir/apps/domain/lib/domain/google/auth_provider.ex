defmodule Domain.Google.AuthProvider do
  use Domain, :schema

  @primary_key false
  schema "google_auth_providers" do
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

    field :is_verified, :boolean, virtual: true, default: false

    field :is_disabled, :boolean, read_after_writes: true, default: false
    field :is_default, :boolean, read_after_writes: true, default: false

    field :name, :string, default: "Google"
    field :hosted_domain, :string

    subject_trail(~w[actor identity system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([:name, :context, :issuer, :is_verified])
    |> validate_acceptance(:is_verified)
    |> validate_length(:hosted_domain, min: 1, max: 255)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:hosted_domain,
      name: :google_auth_providers_account_id_issuer_hosted_domain_index,
      message: "A Google authentication provider for this hosted domain already exists."
    )
    |> unique_constraint(:name,
      name: :google_auth_providers_account_id_name_index,
      message: "A Google authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> foreign_key_constraint(:account_id, name: :google_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :google_auth_providers_auth_provider_id_fkey
    )
  end
end
