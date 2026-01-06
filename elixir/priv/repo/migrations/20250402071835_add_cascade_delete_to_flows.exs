defmodule Portal.Repo.Migrations.AddCascadeDeleteToFlows do
  use Ecto.Migration

  def change do
    # Drop existing foreign key constraints that need to change
    execute("""
    ALTER TABLE flows
    DROP CONSTRAINT flows_policy_id_fkey,
    DROP CONSTRAINT flows_client_id_fkey,
    DROP CONSTRAINT flows_gateway_id_fkey,
    DROP CONSTRAINT flows_resource_id_fkey,
    DROP CONSTRAINT flows_token_id_fkey;
    """)

    # Add new foreign key constraints with ON DELETE CASCADE
    execute("""
    ALTER TABLE flows
    ADD CONSTRAINT flows_policy_id_fkey
      FOREIGN KEY (policy_id)
      REFERENCES policies(id)
      ON DELETE CASCADE,
    ADD CONSTRAINT flows_client_id_fkey
      FOREIGN KEY (client_id)
      REFERENCES clients(id)
      ON DELETE CASCADE,
    ADD CONSTRAINT flows_gateway_id_fkey
      FOREIGN KEY (gateway_id)
      REFERENCES gateways(id)
      ON DELETE CASCADE,
    ADD CONSTRAINT flows_resource_id_fkey
      FOREIGN KEY (resource_id)
      REFERENCES resources(id)
      ON DELETE CASCADE,
    ADD CONSTRAINT flows_token_id_fkey
      FOREIGN KEY (token_id)
      REFERENCES tokens(id)
      ON DELETE CASCADE;
    """)
  end
end
