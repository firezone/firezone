defmodule Portal.Repo.Migrations.AddCreatedByActor do
  use Ecto.Migration

  @table_names ~w[
    actor_groups
    auth_identities
    auth_providers
    gateway_groups
    policies
    relay_groups
    resources
    resource_connections
    tokens
  ]a

  defp migrate_data(table_name) do
    """
    UPDATE #{table_name} AS t
    SET created_by_actor_id = ai.actor_id
    FROM auth_identities AS ai
    WHERE t.created_by_identity_id = ai.id
    AND t.created_by = 'identity'
    AND t.created_by_identity_id is not null;
    """
    |> execute("")
  end

  def change do
    for table_name <- @table_names do
      alter table(table_name) do
        add(:created_by_actor_id, :uuid)
      end

      migrate_data(table_name)
    end
  end
end
