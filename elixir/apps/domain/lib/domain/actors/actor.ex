defmodule Domain.Actors.Actor do
  use Domain, :schema

  schema "actors" do
    field :type, Ecto.Enum,
      values: [:account_user, :account_admin_user, :service_account, :api_client]

    field :name, :string

    has_many :identities, Domain.Auth.Identity

    has_many :clients, Domain.Clients.Client, preload_order: [desc: :last_seen_at]

    has_many :tokens, Domain.Tokens.Token

    has_many :memberships, Domain.Actors.Membership, on_replace: :delete
    has_many :groups, through: [:memberships, :group]

    belongs_to :account, Domain.Accounts.Account

    field :last_seen_at, :utc_datetime_usec, virtual: true
    field :last_synced_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    timestamps()
  end
end
