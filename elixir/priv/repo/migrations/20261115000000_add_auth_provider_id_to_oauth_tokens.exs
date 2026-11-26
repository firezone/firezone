defmodule Portal.Repo.Migrations.AddAuthProviderIdToOauthTokens do
  use Ecto.Migration

  @disable_ddl_transaction true

  @tables [:oauth_authorization_codes, :oauth_tokens]

  # Rows from before this column have no provider and are refused on use, so
  # their clients sign in again once.
  def up do
    for table <- @tables do
      alter table(table) do
        add_if_not_exists(
          :auth_provider_id,
          references(:auth_providers,
            with: [account_id: :account_id],
            type: :binary_id,
            on_delete: :delete_all
          )
        )
      end
    end

    create_if_not_exists(
      index(:oauth_tokens, [:account_id, :auth_provider_id], concurrently: true)
    )
  end

  def down do
    drop_if_exists(index(:oauth_tokens, [:account_id, :auth_provider_id], concurrently: true))

    for table <- @tables do
      alter table(table) do
        remove_if_exists(:auth_provider_id)
      end
    end
  end
end
