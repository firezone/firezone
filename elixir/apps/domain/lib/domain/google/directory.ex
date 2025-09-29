defmodule Domain.Google.Directory do
  use Domain, :schema

  schema "google_directories" do
    belongs_to :account, Domain.Accounts.Account
    field :hosted_domain, :string

    field :issuer, :string
    field :name, :string
    field :superadmin_email, :string
    field :superadmin_emailed_at, :utc_datetime_usec
    field :impersonation_email, :string
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
