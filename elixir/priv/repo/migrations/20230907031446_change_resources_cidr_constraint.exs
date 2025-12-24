defmodule Portal.Repo.Migrations.ChangeResourcesCidrConstraint do
  use Ecto.Migration

  def change do
    execute("""
    ALTER TABLE resources
    DROP CONSTRAINT resources_account_id_cidr_address_index
    """)
  end
end
