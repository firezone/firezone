defmodule Portal.Repo.Migrations.AddClientsHardwareIds do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add(:device_serial, :string)
      add(:device_uuid, :string)
      add(:identifier_for_vendor, :string)
      add(:firebase_installation_id, :string)
    end
  end
end
