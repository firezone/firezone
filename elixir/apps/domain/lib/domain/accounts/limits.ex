defmodule Domain.Accounts.Limits do
  use Ecto.Schema

  embedded_schema do
    field :users_count, :integer
    field :monthly_active_users_count, :integer
    field :service_accounts_count, :integer
    field :sites_count, :integer
    field :account_admin_users_count, :integer
  end
end
