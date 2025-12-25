defmodule Portal.Repo.Migrations.AddFlows do
  use Ecto.Migration

  @assoc_opts [type: :binary_id, on_delete: :nilify_all]

  def change do
    create table(:flows, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:policy_id, references(:policies, @assoc_opts), null: false)
      add(:client_id, references(:clients, @assoc_opts), null: false)
      add(:gateway_id, references(:gateways, @assoc_opts), null: false)
      add(:resource_id, references(:resources, @assoc_opts), null: false)

      add(:client_remote_ip, :inet, null: false)
      add(:client_user_agent, :string, null: false)
      add(:gateway_remote_ip, :inet, null: false)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute("""
    CREATE INDEX flows_account_id_policy_id_index ON flows USING BTREE (account_id, policy_id, inserted_at DESC, id DESC);
    """)

    execute("""
    CREATE INDEX flows_account_id_resource_id_index ON flows USING BTREE (account_id, resource_id, inserted_at DESC, id DESC);
    """)

    execute("""
    CREATE INDEX flows_account_id_client_id_index ON flows USING BTREE (account_id, client_id, inserted_at DESC, id DESC);
    """)

    execute("""
    CREATE INDEX flows_account_id_gateway_id_index ON flows USING BTREE (account_id, gateway_id, inserted_at DESC, id DESC);
    """)
  end
end
