defmodule Portal.Repo.Migrations.CreateMetricsTokenSigningKeys do
  use Ecto.Migration

  def up do
    create table(:metrics_token_signing_keys) do
      add :key, :binary, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    execute("INSERT INTO metrics_token_signing_keys (key) VALUES (gen_random_bytes(32))")
  end

  def down do
    drop table(:metrics_token_signing_keys)
  end
end
