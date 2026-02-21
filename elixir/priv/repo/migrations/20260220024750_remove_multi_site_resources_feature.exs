defmodule Portal.Repo.Migrations.RemoveMultiSiteResourcesFeature do
  use Ecto.Migration

  def up do
    execute(
      "UPDATE accounts SET features = features - 'multi_site_resources' WHERE features ? 'multi_site_resources'"
    )
  end

  def down do
    raise Ecto.MigrationError,
          "multi_site_resources feature data cannot be restored after removal"
  end
end
