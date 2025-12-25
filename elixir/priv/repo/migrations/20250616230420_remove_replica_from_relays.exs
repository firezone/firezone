defmodule Portal.Repo.Migrations.RemoveReplicaFromRelays do
  use Ecto.Migration

  @relations ~w[
    relay_groups
    relays
  ]

  def up do
    for relation <- @relations do
      execute("ALTER TABLE #{relation} REPLICA IDENTITY DEFAULT")
    end
  end

  def down do
    for relation <- @relations do
      execute("ALTER TABLE #{relation} REPLICA IDENTITY FULL")
    end
  end
end
