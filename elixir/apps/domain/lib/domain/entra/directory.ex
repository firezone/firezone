defmodule Domain.Entra.Directory do
  use Domain, :schema

  schema "entra_directories" do
    field :client_id, :string
    field :client_secret, :string
    field :tenant_id, :string

    field :last_error, :string
    field :error_emailed_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    belongs_to :account, Domain.Accounts.Account

    # TODO: IdP sync
    # This can be removed once we rip out the old sync implementation
    belongs_to :auth_provider, Domain.Auth.Provider

    has_many :group_inclusions, Domain.Entra.GroupInclusion, foreign_key: :directory_id

    timestamps()
  end
end
