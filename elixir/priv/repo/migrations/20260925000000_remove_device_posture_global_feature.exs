defmodule Portal.Repo.Migrations.RemoveDevicePostureGlobalFeature do
  use Ecto.Migration

  def up do
    execute("DELETE FROM features WHERE feature = 'device_posture'")
  end

  def down do
    execute("INSERT INTO features (feature, enabled) VALUES ('device_posture', true) ON CONFLICT (feature) DO NOTHING")
  end
end
