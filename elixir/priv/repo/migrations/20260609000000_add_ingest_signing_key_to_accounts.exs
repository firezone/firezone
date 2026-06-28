defmodule Portal.Repo.Migrations.AddIngestSigningKeyToAccounts do
  use Ecto.Migration

  def up do
    alter table(:accounts) do
      add(:ingest_signing_key, :binary, default: fragment("gen_random_bytes(32)"))
    end

    execute(
      "UPDATE accounts SET ingest_signing_key = gen_random_bytes(32) WHERE ingest_signing_key IS NULL;"
    )

    alter table(:accounts) do
      modify(:ingest_signing_key, :binary, null: false)
    end
  end

  def down do
    alter table(:accounts) do
      remove(:ingest_signing_key)
    end
  end
end
