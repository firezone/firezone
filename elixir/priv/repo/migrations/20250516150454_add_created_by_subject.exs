defmodule Portal.Repo.Migrations.AddCreatedBySubject do
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
        add_if_not_exists(:created_by_subject, :jsonb)
      end
    end

    # Clients table is slightly different case
    alter table(:clients) do
      add_if_not_exists(:verified_by_subject, :jsonb)
    end
  end

  def down do
    for table <- @tables do
      alter table(table) do
        remove_if_exists(:created_by_subject)
      end
    end

    # Clients table is slightly different case
    alter table(:clients) do
      remove_if_exists(:verified_by_subject)
    end
  end
end
