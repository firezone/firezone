defmodule Domain.Repo.Migrations.RemovePersistentIdColumns do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      remove(:persistent_id, :uuid)
    end

    alter table(:policies) do
      remove(:persistent_id, :uuid)
    end
  end
end
