defmodule Portal.Repo.Migrations.AddPolicyAuthorizationIdToFlowLogs do
  use Ecto.Migration

  def change do
    alter table(:flow_logs) do
      add(:policy_authorization_id, :binary_id, null: false)
    end
  end
end
