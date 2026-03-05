defmodule Portal.Repo.Migrations.AddConstraintsToStaticDevicePools do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    ALTER TABLE policy_authorizations
    ADD CONSTRAINT policy_authorizations_gateway_or_receiving_client_required
    CHECK (gateway_id IS NOT NULL OR receiving_client_id IS NOT NULL)
    NOT VALID
    """)

    execute("""
    ALTER TABLE policy_authorizations
    VALIDATE CONSTRAINT policy_authorizations_gateway_or_receiving_client_required
    """)

    create_if_not_exists(
      unique_index(:static_device_pool_members, [:account_id, :resource_id, :client_id],
        name: :static_device_pool_members_account_id_resource_id_client_id_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:static_device_pool_members, [:account_id, :resource_id, :client_id],
        name: :static_device_pool_members_account_id_resource_id_client_id_index,
        concurrently: true
      )
    )

    execute("""
    ALTER TABLE policy_authorizations
    DROP CONSTRAINT IF EXISTS policy_authorizations_gateway_or_receiving_client_required
    """)
  end
end
