defmodule Portal.Repo.Migrations.UseTokensForRelayAndGatewayGroups do
  use Ecto.Migration

  def change do
    alter table(:relays) do
      remove(:token_id)
    end

    drop(table(:relay_tokens))

    alter table(:gateways) do
      remove(:token_id)
    end

    drop(table(:gateway_tokens))

    execute("ALTER TABLE tokens ALTER COLUMN expires_at DROP NOT NULL")
    execute("ALTER TABLE tokens ALTER COLUMN account_id DROP NOT NULL")
    execute("ALTER TABLE tokens ALTER COLUMN created_by_user_agent DROP NOT NULL")
    execute("ALTER TABLE tokens ALTER COLUMN created_by_remote_ip DROP NOT NULL")

    alter table(:tokens) do
      add(
        :relay_group_id,
        references(:relay_groups, type: :binary_id, on_delete: :delete_all)
      )

      add(
        :gateway_group_id,
        references(:gateway_groups, type: :binary_id, on_delete: :delete_all)
      )

      add(:remaining_attempts, :integer)
    end

    drop(
      constraint(:tokens, :assoc_not_null,
        check: """
        (type = 'browser' AND actor_id IS NOT NULL AND identity_id IS NOT NULL)
        OR (type = 'email' AND actor_id IS NOT NULL AND identity_id IS NOT NULL)
        OR (type = 'client' AND (
          (identity_id IS NOT NULL AND actor_id IS NOT NULL)
          OR actor_id IS NOT NULL)
        )
        OR (type = 'api_client' AND actor_id IS NOT NULL)
        OR (type IN ('relay', 'gateway'))
        """
      )
    )

    create(
      constraint(:tokens, :assoc_not_null,
        check: """
        (type = 'browser' AND actor_id IS NOT NULL AND identity_id IS NOT NULL)
        OR (type = 'client' AND actor_id IS NOT NULL)
        OR (type = 'email' AND actor_id IS NOT NULL AND identity_id IS NOT NULL)
        OR (type = 'api_client' AND actor_id IS NOT NULL)
        OR (type = 'relay_group' AND relay_group_id IS NOT NULL)
        OR (type = 'gateway_group' AND gateway_group_id IS NOT NULL)
        """
      )
    )
  end
end
