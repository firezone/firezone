defmodule Domain.Repo.Migrations.AddUnprivilegedDeviceConfiguration do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      add(:allow_unprivileged_device_configuration, :boolean)
    end
  end
end
