defmodule Domain.Entra.AuthProvider do
  use Domain, :schema

  @primary_key false
  schema "entra_auth_providers" do
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

    field :client_session_lifetime_secs, :integer
    field :portal_session_lifetime_secs, :integer

    field :is_verified, :boolean, virtual: true, default: false

    field :is_disabled, :boolean, read_after_writes: true, default: false
    field :is_default, :boolean, read_after_writes: true, default: false

    field :name, :string, default: "Entra"

    subject_trail(~w[actor identity system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([:name, :context, :issuer, :is_verified])
    |> validate_acceptance(:is_verified)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:issuer,
      name: :entra_auth_providers_account_id_issuer_index,
      message: "An Entra authentication provider with this issuer already exists."
    )
    |> unique_constraint(:name,
      name: :entra_auth_providers_account_id_name_index,
      message: "An Entra authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> foreign_key_constraint(:account_id, name: :entra_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :entra_auth_providers_auth_provider_id_fkey
    )
  end
end
