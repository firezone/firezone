defmodule Portal.Repo.Migrations.RenameTrustAnchorsFeature do
  use Ecto.Migration

  def change do
    execute(
      "UPDATE features SET feature = 'device_trust' WHERE feature = 'trust_anchors'",
      "UPDATE features SET feature = 'trust_anchors' WHERE feature = 'device_trust'"
    )
  end
end
