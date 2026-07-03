defmodule Portal.Repo.Migrations.AddActorEmailToSessionTables do
  use Ecto.Migration

  # Snapshots the actor's email at session creation so session logs carry it
  # like change and flow logs do, surviving actor deletion and email changes.
  # Nullable: gateway sessions have no actor, service account actors have no
  # email, and rows that predate this column have no recorded snapshot.
  def change do
    alter table(:client_sessions) do
      add(:actor_email, :string)
    end

    alter table(:portal_sessions) do
      add(:actor_email, :string)
    end
  end
end
