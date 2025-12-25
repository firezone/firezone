defmodule Portal.Repo.Migrations.AddTokensApiClients do
  use Ecto.Migration

  def change do
    drop(
      constraint(:tokens, :assoc_not_null,
        check: """
        (type = 'browser' AND identity_id IS NOT NULL)
        OR (type = 'client' AND (
          (identity_id IS NOT NULL AND actor_id IS NOT NULL)
          OR actor_id IS NOT NULL)
        )
        OR (type IN ('relay', 'gateway', 'email', 'api_client'))
        """
      )
    )

    create(
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
  end
end
