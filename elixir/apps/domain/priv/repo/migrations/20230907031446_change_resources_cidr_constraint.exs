defmodule Domain.Repo.Migrations.ChangeResourcesCidrConstraint do
  use Ecto.Migration

  def change do
    execute("""
    ALTER TABLE resources
    DROP CONSTRAINT resources_account_id_cidr_address_index
    """)

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT resources_account_id_cidr_address_index
    EXCLUDE USING gist (account_id WITH =, (address::inet) inet_ops WITH &&)
    WHERE (
      type = 'cidr'
      AND (
        (family(address::inet) = 6 AND address::inet << inet 'FD00:2021:1111::/106')
        OR
        (family(address::inet) = 4 AND address::inet << inet '100.64.0.0/10')
      )
    )
    """)
  end
end
