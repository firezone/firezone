defmodule Domain.Entra.Directory do
  use Domain, :schema

  schema "entra_directories" do
    field :groups_delta_link, :string
    field :users_delta_link, :string

    field :tenant_id, :string

    field :last_error, :string
    field :error_emailed_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    belongs_to :account, Domain.Accounts.Account
    belongs_to :auth_provider, Domain.Auth.Provider

    has_many :group_inclusions, Domain.Entra.GroupInclusion

    timestamps()
  end
end
