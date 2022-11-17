defmodule FzHttp.Repo.Migrations.AddUserIdToRules do
  use Ecto.Migration

  def change do
    drop unique_index(:rules, [:destination, :action])

    alter table(:rules) do
      add :user_id, references(:users, on_delete: :delete_all), default: nil
    end

    execute("
      DELETE FROM rules r1
      USING rules r2
      WHERE r2.destination >> r1.destination
      AND r2.action = r1.action
      AND r1.user_id IS NULL
      AND r2.user_id IS NULL
    ")

    execute("
      DELETE FROM rules r1
      USING rules r2
      WHERE r2.destination >> r1.destination
      AND r2.action = r1.action
      AND r2.user_id = r1.user_id
    ")

    execute(
      "CREATE EXTENSION IF NOT EXISTS btree_gist",
      "DROP EXTENSION btree_gist"
    )

    execute(
      "ALTER TABLE rules
        ADD CONSTRAINT destination_overlap_excl_usr_rule EXCLUDE USING gist (destination inet_ops WITH &&, user_id WITH =, action WITH =) WHERE (user_id IS NOT NULL)",
      "ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl_usr_rule"
    )

    execute(
      "ALTER TABLE rules
        ADD CONSTRAINT destination_overlap_excl EXCLUDE USING gist (destination inet_ops WITH &&, action WITH =) WHERE (user_id IS NULL)",
      "ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl"
    )
  end
end
