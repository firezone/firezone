defmodule Portal.Repo.Migrations.AddIsDisabledToActors do
  use Ecto.Migration

  def up do
    alter table(:actors) do
      add(:is_disabled, :boolean, default: false, null: false)
    end

    execute("UPDATE actors SET is_disabled = true WHERE disabled_at IS NOT NULL")
  end

  def down do
    alter table(:actors) do
      remove(:is_disabled)
    end
  end
end
