defmodule Domain.Okta.Directory do
  use Domain, :schema

  schema "okta_directories" do
    belongs_to :account, Domain.Accounts.Account

    field :client_id, :string
    field :private_key_jwk, :map
    field :kid, :string
    field :okta_domain, :string

    field :issuer, :string
    field :name, :string
    field :error_count, :integer, read_after_writes: true
    field :disabled_at, :utc_datetime_usec
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :error, :string
    field :error_emailed_at, :utc_datetime_usec

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
