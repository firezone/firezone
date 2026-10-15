defmodule Portal.Repo.Migrations.AddAccountInactivityTracking do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # Existing accounts get a full year from rollout, not a guessed history.
      add(:last_active_at, :timestamptz, null: false, default: fragment("CURRENT_TIMESTAMP"))
      add(:inactivity_reminded_at, :timestamptz)
    end

    # A durable watermark survives Oban job pruning and worker downtime.
    create table(:account_activity_rollups, primary_key: false) do
      add(:id, :boolean, primary_key: true, default: true)
      add(:processed_until, :timestamptz, null: false, default: fragment("CURRENT_TIMESTAMP"))
    end

    create(constraint(:account_activity_rollups, :singleton, check: "id = true"))

    execute(
      "INSERT INTO account_activity_rollups (id) VALUES (true)",
      "DELETE FROM account_activity_rollups"
    )
  end
end
