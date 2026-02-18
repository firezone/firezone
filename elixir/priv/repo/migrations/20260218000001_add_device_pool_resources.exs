defmodule Portal.Repo.Migrations.AddDevicePoolResources do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type IN ('internet', 'static_device_pool') AND address IS NULL)
    );
    """)

    create table(:static_device_pool_members, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :resource_id,
        references(:resources,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(
        :client_id,
        references(:clients,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )
    end

    create(index(:static_device_pool_members, [:resource_id]))
    create(index(:static_device_pool_members, [:client_id]))
  end

  def down do
    drop(table(:static_device_pool_members))

    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type = 'internet' AND address IS NULL)
    );
    """)
  end
end
