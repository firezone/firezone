defmodule Portal.Repo.Migrations.AddPoliciesDisabledFields do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add(:disabled_at, :utc_datetime_usec)
    end
  end
end
