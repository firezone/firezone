defmodule Domain.Repo.Migrations.CreateOneTimePasscodes do
  use Ecto.Migration

  def change do
    create table(:one_time_passcodes, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id), primary_key: true, null: false)
      add(:id, :uuid, primary_key: true)
      add(:actor_id, :binary_id, null: false)

      add(:code_hash, :string, null: false)

      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    # Composite foreign key for (account_id, actor_id) -> actors(account_id, id)
    execute(
      """
      ALTER TABLE one_time_passcodes
      ADD CONSTRAINT one_time_passcodes_actor_id_fkey
      FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE one_time_passcodes DROP CONSTRAINT one_time_passcodes_actor_id_fkey"
    )

    create(index(:one_time_passcodes, [:actor_id]))
    create(index(:one_time_passcodes, [:expires_at]))

    # Delete all email tokens from the tokens table - these are short-lived, so should not cause
    # any real disruption
    execute(
      "DELETE FROM tokens WHERE type = 'email'",
      ""
    )

    # Update the type constraint to remove 'email'
    drop(constraint(:tokens, :type_must_be_valid))

    create(
      constraint(:tokens, :type_must_be_valid,
        check: "type IN ('browser', 'client', 'api_client')"
      )
    )
  end
end
