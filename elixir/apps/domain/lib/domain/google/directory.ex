defmodule Domain.Google.Directory do
  use Domain, :schema

  @primary_key false
  schema "google_directories" do
    belongs_to :account, Domain.Accounts.Account
    belongs_to :directory, Domain.Directories.Directory, primary_key: true

    field :name, :string
    field :hosted_domain, :string
    field :error_count, :integer, read_after_writes: true
    field :disabled_at, :utc_datetime_usec
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :error, :string
    field :error_emailed_at, :utc_datetime_usec
    field :jit_provisioning, :boolean

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
