defmodule Portal.Repo.Migrations.WidenActorsTypeConstraint do
  use Ecto.Migration

  def up do
    drop(constraint(:actors, :type_is_valid))

    create(
      constraint(:actors, :type_is_valid,
        check: """
          (type IN ('account_user', 'account_admin_user') AND email IS NOT NULL)
          OR (type = 'firezone_support' AND email LIKE '%+firezone-support@firezone.dev')
          OR (type IN ('service_account', 'api_client') AND email IS NULL)
        """
      )
    )
  end

  def down do
    drop(constraint(:actors, :type_is_valid))

    create(
      constraint(:actors, :type_is_valid,
        check: """
          (type IN ('account_user', 'account_admin_user') AND email IS NOT NULL)
          OR (type IN ('service_account', 'api_client') AND email IS NULL)
        """
      )
    )
  end
end
