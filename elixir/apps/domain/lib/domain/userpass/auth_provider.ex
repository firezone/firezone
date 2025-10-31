defmodule Domain.Userpass.AuthProvider do
  use Domain, :schema

  @fields ~w[name context issuer is_disabled]a

  @primary_key false
  schema "userpass_auth_providers" do
    # Allows setting the ID manually in changesets
    field :id, Ecto.UUID, primary_key: true

    belongs_to :account, Domain.Accounts.Account

    belongs_to :auth_provider, Domain.AuthProviders.AuthProvider,
      foreign_key: :id,
      define_field: false

    field :name, :string
    field :issuer, :string, read_after_writes: true

    field :context, Ecto.Enum,
      values: ~w[clients_and_portal clients_only portal_only]a,
      default: :clients_and_portal

    field :is_disabled, :boolean, read_after_writes: true, default: false

    subject_trail(~w[actor system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([:name, :context])
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:account_id,
      name: :userpass_auth_providers_pkey,
      message: "A Username & Password authentication provider for this account already exists."
    )
    |> unique_constraint(:name,
      name: :userpass_auth_providers_account_id_name_index,
      message: "A Username & Password authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> check_constraint(:issuer, name: :issuer_must_be_firezone)
    |> foreign_key_constraint(:account_id, name: :userpass_auth_providers_account_id_fkey)
    |> foreign_key_constraint(:auth_provider_id,
      name: :userpass_auth_providers_auth_provider_id_fkey
    )
  end

  def fields, do: @fields
end
