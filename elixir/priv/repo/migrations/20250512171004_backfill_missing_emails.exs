defmodule Portal.Repo.Migrations.BackfillMissingEmails do
  use Ecto.Migration

  def up do
    execute("""
      UPDATE auth_identities ai
      SET email = ai.provider_identifier
      FROM auth_providers ap
      WHERE ai.provider_id = ap.id
      AND ap.adapter = 'email'
      AND ai.email IS NULL;
    """)
  end

  def down do
    # Nothing to do as we don't know which records to rollback
  end
end
