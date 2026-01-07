defmodule Portal.Repo.Migrations.AddInternetResources do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE resources ALTER COLUMN address DROP NOT NULL")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type = 'internet' AND address IS NULL)
    );
    """)

    create(
      index(:resources, [:account_id, :type],
        unique: true,
        where: "type = 'internet'",
        name: "unique_internet_resource_per_account"
      )
    )
  end
end
