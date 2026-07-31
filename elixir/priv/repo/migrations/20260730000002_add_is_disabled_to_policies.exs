defmodule Portal.Repo.Migrations.AddIsDisabledToPolicies do
  use Ecto.Migration

  def up do
    alter table(:policies) do
      add(:is_disabled, :boolean, default: false, null: false)
    end

    execute("UPDATE policies SET is_disabled = true WHERE disabled_at IS NOT NULL")
  end

  def down do
    alter table(:policies) do
      remove(:is_disabled)
    end
  end
end
