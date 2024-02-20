defmodule Domain.Accounts.Limits do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :monthly_active_users_count, :integer
    field :service_accounts_count, :integer
    field :gateway_groups_count, :integer
    field :account_admin_users_count, :integer
  end
end
