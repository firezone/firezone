defmodule Portal.Repo.Migrations.NormalizeExternalIdentitiesTimestamps do
  use Ecto.Migration

  # Part of the timestamp -> timestamptz normalization. See
  # 20260608000000_normalize_accounts_timestamps for the full rationale.

  def up do
    convert("timestamptz")
  end

  def down do
    convert("timestamp")
  end

  defp convert(target_type) do
    execute("SET LOCAL timezone TO 'UTC'")
    execute("SET LOCAL lock_timeout TO '5s'")

    execute(~s|ALTER TABLE "external_identities" ALTER COLUMN "inserted_at" DROP DEFAULT|)
    execute(~s|ALTER TABLE "external_identities" ALTER COLUMN "inserted_at" TYPE #{target_type}, ALTER COLUMN "updated_at" TYPE #{target_type}|)
    # Re-created so the catalog holds a native default for the new type
    # instead of one rewritten through a cast.
    execute(~s|ALTER TABLE "external_identities" ALTER COLUMN "inserted_at" SET DEFAULT now()|)
  end
end
