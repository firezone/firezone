defmodule Portal.Repo.Replica.Migrations.AddLimitExceededFlagsToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # Add boolean flags for each limit type
      add(:users_limit_exceeded, :boolean, default: false, null: false)
      add(:seats_limit_exceeded, :boolean, default: false, null: false)
      add(:service_accounts_limit_exceeded, :boolean, default: false, null: false)
      add(:sites_limit_exceeded, :boolean, default: false, null: false)
      add(:admins_limit_exceeded, :boolean, default: false, null: false)

      # Remove the old warning text field and delivery attempts counter
      remove(:warning, :string)
      remove(:warning_delivery_attempts, :integer)
    end
  end
end
