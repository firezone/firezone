defmodule Portal.Repo.Migrations.UpdateVerifiedByConstraint do
  use Ecto.Migration

  def change do
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS verified_fields_set
    """)

    create(
      constraint(:clients, :verified_fields_set,
        check: """
        (
          verified_at IS NULL
          AND verified_by IS NULL
          AND verified_by_subject IS NULL
        )
        OR
        (
          verified_at IS NOT NULL
          AND verified_by IS NOT NULL
          AND verified_by_subject IS NOT NULL
        )
        """
      )
    )
  end
end
