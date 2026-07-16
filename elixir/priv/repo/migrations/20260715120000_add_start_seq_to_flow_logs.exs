defmodule Portal.Repo.Migrations.AddStartSeqToFlowLogs do
  use Ecto.Migration

  def change do
    alter table(:flow_logs) do
      add(:start_seq, :bigint)
    end
  end
end
