# TODO: service accounts auth as clients and as API clients?
defmodule Domain.Tokens.Token do
  use Domain, :schema

  schema "tokens" do
    field :context, Ecto.Enum, values: [:browser, :client, :relay, :gateway, :email, :api_client]

    field :secret, :string, virtual: true, redact: true
    field :secret_salt, :string
    field :secret_hash, :string

    field :user_agent, :string
    field :remote_ip, Domain.Types.IP

    belongs_to :account, Domain.Accounts.Account

    # Maybe this is not needed and they should be in the join tables (eg. relay_group_tokens)
    field :created_by, Ecto.Enum, values: ~w[system identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :expires_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
