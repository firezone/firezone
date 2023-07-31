defmodule Domain.Auth.Identity do
  use Domain, :schema

  schema "auth_identities" do
    belongs_to :actor, Domain.Actors.Actor
    belongs_to :provider, Domain.Auth.Provider

    field :provider_identifier, :string
    field :provider_state, :map
    field :provider_virtual_state, :map, virtual: true

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Domain.Types.IP
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, Domain.Accounts.Account

    field :created_by, Ecto.Enum, values: ~w[system provider identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
  end
end
