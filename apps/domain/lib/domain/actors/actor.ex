defmodule Domain.Actors.Actor do
  use Domain, :schema

  schema "actors" do
    field :type, Ecto.Enum, values: [:user, :service_account]
    field :role, Ecto.Enum, values: [:unprivileged, :admin]

    has_many :identities, Domain.Auth.Identity

    # belongs_to :group, Domain.Actors.Group
    belongs_to :account, Domain.Accounts.Account

    # has_many :oidc_connections, Domain.Auth.OIDC.Connection
    has_many :api_tokens, Domain.ApiTokens.ApiToken

    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
