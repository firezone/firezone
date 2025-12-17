defmodule Portal.Repo.Migrations.AddResourcesType do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      add(:type, :string, null: false)
    end

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT resources_account_id_cidr_address_index
    EXCLUDE USING gist (account_id WITH =, (address::inet) inet_ops WITH &&)
    WHERE (type = 'cidr')
    """)
  end
end
