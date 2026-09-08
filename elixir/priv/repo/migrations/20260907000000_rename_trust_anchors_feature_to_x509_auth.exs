defmodule Portal.Repo.Migrations.RenameTrustAnchorsFeatureToX509Auth do
  use Ecto.Migration

  def change do
    execute(
      "UPDATE features SET feature = 'x509_auth' WHERE feature = 'trust_anchors'",
      "UPDATE features SET feature = 'trust_anchors' WHERE feature = 'x509_auth'"
    )
  end
end
