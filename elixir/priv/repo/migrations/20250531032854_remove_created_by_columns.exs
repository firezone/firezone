defmodule Portal.Repo.Migrations.RemoveCreatedByColumns do
  use Ecto.Migration

  @tables [
    :actor_groups,
    :auth_identities,
    :auth_providers,
    :gateway_groups,
    :policies,
    :relay_groups,
    :resource_connections,
    :resources,
    :tokens
  ]

  def up do
    for table <- @tables do
      alter table(table) do
        remove_if_exists(:created_by_actor_id)
        remove_if_exists(:created_by_identity_id)
      end
    end

    # Clients table is slightly different case
    alter table(:clients) do
      remove_if_exists(:verified_by_actor_id)
      remove_if_exists(:verified_by_identity_id)
    end
  end

  def down do
    for table <- @tables do
      alter table(table) do
        add_if_not_exists(
          :created_by_actor_id,
          references(:actors, type: :binary_id)
        )

        add_if_not_exists(
          :created_by_identity_id,
          references(:auth_identities, type: :binary_id)
        )
      end
    end

    # Clients table is slightly different case
    alter table(:clients) do
      add_if_not_exists(
        :verified_by_actor_id,
        references(:actors, type: :binary_id)
      )

      add_if_not_exists(
        :verified_by_identity_id,
        references(:auth_identities, type: :binary_id)
      )
    end
  end
end
