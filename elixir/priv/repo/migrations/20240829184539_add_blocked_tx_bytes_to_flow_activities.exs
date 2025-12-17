defmodule Portal.Repo.Migrations.AddBlockedTxBytesToFlowActivities do
  use Ecto.Migration

  def change do
    alter table(:flow_activities) do
      add(:blocked_tx_bytes, :bigint, null: false, default: 0)
    end
  end
end
