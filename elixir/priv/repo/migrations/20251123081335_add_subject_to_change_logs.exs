defmodule Portal.Repo.Migrations.AddSubjectToChangeLogs do
  use Ecto.Migration

  def change do
    alter table(:change_logs) do
      add(:subject, :jsonb)
    end
  end
end
