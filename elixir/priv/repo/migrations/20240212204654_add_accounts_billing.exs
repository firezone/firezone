defmodule Portal.Repo.Migrations.AddAccountsBilling do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:features, :map, default: %{}, null: false)
      add(:limits, :map, default: %{}, null: false)
      add(:config, :map, default: %{}, null: false)
      add(:metadata, :map, default: %{}, null: false)

      add(:warning, :text)
      add(:warning_delivery_attempts, :integer)
      add(:warning_last_sent_at, :utc_datetime_usec)

      add(:disabled_reason, :text)
      add(:disabled_at, :utc_datetime_usec)
    end
  end
end
