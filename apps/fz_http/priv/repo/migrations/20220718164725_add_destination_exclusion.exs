defmodule FzHttp.Repo.Migrations.AddDestinationExclusion do
  use Ecto.Migration

  def change do
    drop unique_index(:rules, [:user_id, :destination, :action])

    execute(
      "CREATE EXTENSION btree_gist",
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
