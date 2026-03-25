defmodule Portal.Repo.Migrations.DropRedundantIndexes do
  use Ecto.Migration

  def up do
    drop_if_exists(
      index(:policy_authorizations, [:account_id, :client_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_client_id_index
      )
    )

    drop_if_exists(
      index(:policy_authorizations, [:account_id, :gateway_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_gateway_id_index
      )
    )

    drop_if_exists(
      index(:policy_authorizations, [:account_id, :policy_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_policy_id_index
      )
    )

    drop_if_exists(
      index(:policy_authorizations, [:account_id, :resource_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_resource_id_index
      )
    )

    drop_if_exists(
      index(:policy_authorizations, [:account_id, :token_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_token_id_index
      )
    )

    drop_if_exists(
      index(:policy_authorizations, [:account_id, :membership_id, :inserted_at, :id],
        name: :policy_authorizations_membership_id_index
      )
    )
  end

  def down do
    create_if_not_exists(
      index(:policy_authorizations, [:account_id, :client_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_client_id_index,
        order: [inserted_at: :desc, id: :desc]
      )
    )

    create_if_not_exists(
      index(:policy_authorizations, [:account_id, :gateway_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_gateway_id_index,
        order: [inserted_at: :desc, id: :desc]
      )
    )

    create_if_not_exists(
      index(:policy_authorizations, [:account_id, :policy_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_policy_id_index,
        order: [inserted_at: :desc, id: :desc]
      )
    )

    create_if_not_exists(
      index(:policy_authorizations, [:account_id, :resource_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_resource_id_index,
        order: [inserted_at: :desc, id: :desc]
      )
    )

    create_if_not_exists(
      index(:policy_authorizations, [:account_id, :token_id, :inserted_at, :id],
        name: :policy_authorizations_account_id_token_id_index,
        order: [inserted_at: :desc, id: :desc]
      )
    )

    create_if_not_exists(
      index(:policy_authorizations, [:account_id, :membership_id, :inserted_at, :id],
        name: :policy_authorizations_membership_id_index,
        order: [inserted_at: :desc, id: :desc]
      )
    )
  end
end
