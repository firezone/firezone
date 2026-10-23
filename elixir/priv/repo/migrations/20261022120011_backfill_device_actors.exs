defmodule Portal.Repo.Migrations.BackfillDeviceActors do
  @moduledoc """
  Every client device so far belongs to exactly one actor, recorded in
  `devices.actor_id`. That link is copied into `device_actors` so the join
  table covers existing devices before anything starts reading it.

  A device was created on its first connect, so `inserted_at` is when the
  actor was first seen on it. Rows that connects have already written keep
  the earlier first-seen and the later last-seen time.
  """
  use Ecto.Migration

  def up do
    execute(backfill_statement())
  end

  def down do
    # Rows are the ones derived from the owner column; connect-written rows
    # for the same pair are indistinguishable, so the whole table is cleared.
    execute("DELETE FROM device_actors")
  end

  def backfill_statement do
    """
    INSERT INTO device_actors (account_id, device_id, actor_id, first_seen_at, last_seen_at)
    SELECT d.account_id, d.id, d.actor_id, d.inserted_at, COALESCE(d.last_seen_at, d.inserted_at)
    FROM devices d
    WHERE d.type = 'client' AND d.actor_id IS NOT NULL
    ON CONFLICT (account_id, device_id, actor_id) DO UPDATE SET
      first_seen_at = LEAST(device_actors.first_seen_at, EXCLUDED.first_seen_at),
      last_seen_at = GREATEST(device_actors.last_seen_at, EXCLUDED.last_seen_at)
    """
  end
end
