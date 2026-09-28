defmodule Portal.Repo.Migrations.AddAesGcmFeature do
  use Ecto.Migration

  def change do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('aes_gcm', false) ON CONFLICT (feature) DO NOTHING",
      "DELETE FROM features WHERE feature = 'aes_gcm'"
    )
  end
end
