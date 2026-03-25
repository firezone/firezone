defmodule Portal.Repo.Migrations.AddReceivingClientIdToPolicyAuthorizations do
  use Ecto.Migration

  def up do
    alter table(:policy_authorizations) do
      modify(:gateway_id, :binary_id, null: true)
      modify(:gateway_remote_ip, :inet, null: true)

      add(
        :receiving_client_id,
        references(:clients,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        )
      )
    end

    drop_if_exists(
      index(:policy_authorizations, [:gateway_id], name: :policy_authorizations_gateway_id_index)
    )

    create(
      index(:policy_authorizations, [:gateway_id],
        name: :policy_authorizations_gateway_id_index,
        where: "gateway_id IS NOT NULL"
      )
    )

    create(
      index(:policy_authorizations, [:receiving_client_id],
        name: :policy_authorizations_receiving_client_id_index,
        where: "receiving_client_id IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:policy_authorizations, [:gateway_id], name: :policy_authorizations_gateway_id_index)
    )

    create(
      index(:policy_authorizations, [:gateway_id], name: :policy_authorizations_gateway_id_index)
    )

    drop_if_exists(
      index(:policy_authorizations, [:receiving_client_id],
        name: :policy_authorizations_receiving_client_id_index
      )
    )

    alter table(:policy_authorizations) do
      modify(:gateway_id, :binary_id, null: false)
      modify(:gateway_remote_ip, :inet, null: false)

      remove(:receiving_client_id)
    end
  end
end
