defmodule Portal.Repo.Migrations.AddDevicePostureFeature do
  use Ecto.Migration

  def change do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('device_posture', false) ON CONFLICT (feature) DO NOTHING",
      "DELETE FROM features WHERE feature = 'device_posture'"
    )
  end
end
