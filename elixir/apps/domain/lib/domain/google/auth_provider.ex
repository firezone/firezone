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

    field :is_verified, :boolean, virtual: true, default: true

    field :is_disabled, :boolean, read_after_writes: true, default: false
    field :is_default, :boolean, read_after_writes: true, default: false

    field :name, :string, default: "Google"
    field :hosted_domain, :string

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
