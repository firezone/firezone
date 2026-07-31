defmodule Portal.Repo.Migrations.DropDisabledAtFromAccountsActorsPolicies do
  use Ecto.Migration

  def up do
    alter table(:accounts) do
      remove(:disabled_at)
    end

    alter table(:actors) do
      remove(:disabled_at)
    end

    alter table(:policies) do
      remove(:disabled_at)
    end
  end

  def down do
    alter table(:accounts) do
      add(:disabled_at, :utc_datetime_usec)
    end

    alter table(:actors) do
      add(:disabled_at, :utc_datetime_usec)
    end

    alter table(:policies) do
      add(:disabled_at, :utc_datetime_usec)
    end
  end
end
