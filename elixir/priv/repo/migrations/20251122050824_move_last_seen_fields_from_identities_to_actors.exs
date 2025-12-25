defmodule Portal.Repo.Migrations.MoveLastSeenFieldsFromIdentitiesToActors do
  use Ecto.Migration

  def up do
    # Remove last_seen fields from external_identities table
    alter table(:external_identities) do
      remove(:last_seen_user_agent)
      remove(:last_seen_remote_ip)
      remove(:last_seen_remote_ip_location_region)
      remove(:last_seen_remote_ip_location_city)
      remove(:last_seen_remote_ip_location_lat)
      remove(:last_seen_remote_ip_location_lon)
      remove(:last_seen_at)
    end
  end

  def down do
    # Add last_seen fields back to external_identities table
    alter table(:external_identities) do
      add(:last_seen_user_agent, :string)
      add(:last_seen_remote_ip, :inet)
      add(:last_seen_remote_ip_location_region, :string)
      add(:last_seen_remote_ip_location_city, :string)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
      add(:last_seen_at, :utc_datetime_usec)
    end
  end
end
