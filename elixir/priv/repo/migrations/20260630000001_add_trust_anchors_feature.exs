defmodule Portal.Repo.Migrations.AddTrustAnchorsFeature do
  use Ecto.Migration

  def change do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('trust_anchors', false)",
      "DELETE FROM features WHERE feature = 'trust_anchors'"
    )
  end
end
