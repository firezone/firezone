defmodule Portal.Repo.Migrations.RenameDeviceTrustFeatureToTrustAnchors do
  use Ecto.Migration

  def change do
    execute(
      "UPDATE features SET feature = 'trust_anchors' WHERE feature = 'device_trust'",
      "UPDATE features SET feature = 'device_trust' WHERE feature = 'trust_anchors'"
    )
  end
end
