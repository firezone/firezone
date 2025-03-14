defmodule Domain.Auth.Provider do
  use Domain, :schema

  schema "auth_providers" do
    field :name, :string

    field :adapter, Ecto.Enum,
      values:
        ~w[email openid_connect google_workspace microsoft_entra okta jumpcloud mock userpass]a

    field :provisioner, Ecto.Enum, values: ~w[manual just_in_time custom]a
    field :adapter_config, :map, redact: true
    field :adapter_state, :map, redact: true

    belongs_to :account, Domain.Accounts.Account

    has_many :actor_groups, Domain.Actors.Group, where: [deleted_at: nil]
    has_many :identities, Domain.Auth.Identity, where: [deleted_at: nil]

    field :created_by, Ecto.Enum, values: ~w[system identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :last_syncs_failed, :integer
    field :last_sync_error, :string
    field :last_synced_at, :utc_datetime_usec
    field :sync_disabled_at, :utc_datetime_usec
    field :sync_error_emailed_at, :utc_datetime_usec

    field :group_filters_enabled_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
