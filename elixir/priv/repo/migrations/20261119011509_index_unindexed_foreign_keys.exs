defmodule Portal.Repo.Migrations.IndexUnindexedForeignKeys do
  use Ecto.Migration

  @disable_ddl_transaction true

  @indexes [
    {:feedback_submissions, [:account_id], nil},
    {:outbound_emails, [:account_id], "account_id IS NOT NULL"},
    {:outbound_email_deliveries, [:account_id], "account_id IS NOT NULL"},
    {:oauth_tokens, [:account_id, :actor_id], nil},
    {:pending_identities, [:account_id, :actor_id], nil},
    {:pending_identities, [:account_id, :directory_id], "directory_id IS NOT NULL"},
    {:pending_identities, [:account_id, :auth_provider_id], nil},
    {:pending_identities, [:account_id, :one_time_passcode_id], nil},
    {:oauth_authorization_codes, [:account_id, :actor_id], nil},
    {:oauth_authorization_codes, [:account_id, :auth_provider_id],
     "auth_provider_id IS NOT NULL"},
    {:oauth_authorization_codes, [:account_id, :oauth_grant_id], nil},
    {:oauth_authorization_codes, [:oauth_client_id], nil},
    {:oauth_grants, [:oauth_client_id], nil}
  ]

  def up do
    for {table, columns, where} <- @indexes do
      create_if_not_exists(index(table, columns, where: where, concurrently: true))
    end

    create_if_not_exists(
      index(:policy_authorizations, [:membership_id],
        where: "membership_id IS NOT NULL",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:policy_authorizations, [:membership_id],
        name: :policy_authorizations_membership_id_idx,
        concurrently: true
      )
    )
  end

  def down do
    create_if_not_exists(
      index(:policy_authorizations, [:membership_id],
        name: :policy_authorizations_membership_id_idx,
        concurrently: true
      )
    )

    drop_if_exists(index(:policy_authorizations, [:membership_id], concurrently: true))

    for {table, columns, _where} <- @indexes do
      drop_if_exists(index(table, columns, concurrently: true))
    end
  end
end
