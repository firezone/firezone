defmodule Portal.Repo.Migrations.AddGeoipLocationFields do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add(:last_seen_remote_ip_location_region, :text)
      add(:last_seen_remote_ip_location_city, :text)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
    end

    alter table(:relays) do
      add(:last_seen_remote_ip_location_region, :text)
      add(:last_seen_remote_ip_location_city, :text)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
    end

    alter table(:gateways) do
      add(:last_seen_remote_ip_location_region, :text)
      add(:last_seen_remote_ip_location_city, :text)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
    end

    alter table(:auth_identities) do
      add(:last_seen_remote_ip_location_region, :text)
      add(:last_seen_remote_ip_location_city, :text)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
    end
  end
end
