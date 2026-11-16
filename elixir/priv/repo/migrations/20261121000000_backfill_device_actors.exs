defmodule Portal.Repo.Migrations.BackfillDeviceActors do
  use Ecto.Migration

  # Every node records device actors on connect since the previous deploy.
  # This adds the Clients that have not connected since. A row a connect
  # already wrote is kept, because it has the newer last_seen_at.
  def up do
    execute("""
    INSERT INTO device_actors (account_id, device_id, actor_id, first_seen_at, last_seen_at)
    SELECT d.account_id, d.id, d.actor_id, d.inserted_at, COALESCE(d.last_seen_at, d.inserted_at)
    FROM devices AS d
    WHERE d.type = 'client' AND d.actor_id IS NOT NULL
    ON CONFLICT DO NOTHING
    """)
  end

  def down, do: :ok
end
