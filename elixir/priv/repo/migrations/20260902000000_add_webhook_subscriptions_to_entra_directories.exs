defmodule Portal.Repo.Migrations.AddWebhookSubscriptionsToEntraDirectories do
  use Ecto.Migration

  def change do
    alter table(:entra_directories) do
      add(:webhook_secret, :string)
      add(:users_subscription_id, :string)
      add(:groups_subscription_id, :string)
      add(:subscriptions_expire_at, :timestamptz)
    end
  end
end
