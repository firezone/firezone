defmodule Portal.Repo.Migrations.NormalizeGatewayTokensTimestamps do
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

    execute(~s|ALTER TABLE "gateway_tokens" ALTER COLUMN "inserted_at" TYPE #{target_type}|)
  end
end
