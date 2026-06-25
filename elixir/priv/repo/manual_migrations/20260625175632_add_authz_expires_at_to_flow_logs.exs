defmodule Portal.Repo.Migrations.AddAuthzExpiresAtToFlowLogs do
  use Ecto.Migration

  def change do
    alter table(:flow_logs) do
      add(:authorization_expires_at, :timestamptz, null: false)
    end
  end
end
