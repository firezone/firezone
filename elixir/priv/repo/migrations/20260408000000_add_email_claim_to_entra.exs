defmodule Portal.Repo.Migrations.AddEmailClaimToEntra do
  use Ecto.Migration

  def up do
    # Default existing rows to "email"/"mail" to preserve current behavior
    alter table(:entra_auth_providers) do
      add(:email_claim, :string, null: false, default: "email")
    end

    alter table(:entra_directories) do
      add(:email_field, :string, null: false, default: "mail")
    end

    # Change DB defaults for future inserts to stronger claims
    execute("ALTER TABLE entra_auth_providers ALTER COLUMN email_claim SET DEFAULT 'upn'")

    execute(
      "ALTER TABLE entra_directories ALTER COLUMN email_field SET DEFAULT 'userPrincipalName'"
    )
  end

  def down do
    alter table(:entra_auth_providers) do
      remove(:email_claim)
    end

    alter table(:entra_directories) do
      remove(:email_field)
    end
  end
end
