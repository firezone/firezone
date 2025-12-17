defmodule Portal.Repo.Migrations.AddSubjectTrailToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:created_by, :string)
      add(:created_by_subject, :jsonb)
    end
  end
end
