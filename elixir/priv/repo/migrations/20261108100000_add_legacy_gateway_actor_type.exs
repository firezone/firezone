defmodule Portal.Repo.Migrations.AddLegacyGatewayActorType do
  use Ecto.Migration

  # The actor that owns legacy Gateway tokens has no email, like service
  # accounts. The wider check is added unvalidated so the table is not scanned
  # under this lock; every existing row already satisfies it.
  def up do
    drop(constraint(:actors, :type_is_valid))

    create(
      constraint(:actors, :type_is_valid,
        check: """
          (type IN ('account_user', 'account_admin_user') AND email IS NOT NULL)
          OR (type IN ('service_account', 'api_client', 'legacy_gateway') AND email IS NULL)
        """,
        validate: false
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
