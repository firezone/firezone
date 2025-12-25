defmodule Portal.Repo.Migrations.IndexAuthProvidersOnAdapter do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # Used for refresh access token job which uses a cross-account query,
    # so account_id is intentionally not included in the index.
    create_if_not_exists(
      index(
        :auth_providers,
        [:adapter],
        where: "disabled_at IS NULL AND deleted_at IS NULL",
        name: :index_auth_providers_on_adapter
      )
    )
  end

  def down do
    drop_if_exists(index(:auth_providers, [:adapter], name: :index_auth_providers_on_adapter))
  end
end
