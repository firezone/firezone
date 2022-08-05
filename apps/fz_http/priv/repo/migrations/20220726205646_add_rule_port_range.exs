defmodule FzHttp.Repo.Migrations.AddRulePortRange do
  use Ecto.Migration

  @create_query "CREATE TYPE port_type_enum AS ENUM ('tcp', 'udp')"
  @drop_query "DROP TYPE port_type_enum"

  def change do
    execute("ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl_usr_rule")

    execute("ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl")

    execute(@create_query, @drop_query)

    alter table(:rules) do
      add :port_range, :int4range, default: nil
      add :port_type, :port_type_enum, default: nil
    end

    create constraint("rules", :port_range_needs_type,
             check: "(port_range IS NULL) = (port_type IS NULL)"
           )

    create constraint("rules", :port_range_is_within_valid_values,
             check: "port_range <@ int4range(1, 65535)"
           )

    execute(
      "ALTER TABLE rules
        ADD CONSTRAINT destination_overlap_excl EXCLUDE USING gist (destination inet_ops WITH &&, action WITH =) WHERE (user_id IS NULL AND port_range IS NULL)",
      "ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl"
    )

    execute(
      "ALTER TABLE rules
        ADD CONSTRAINT destination_overlap_excl_usr_rule EXCLUDE USING gist (destination inet_ops WITH &&, user_id WITH =, action WITH =) WHERE (user_id IS NOT NULL AND port_range IS NULL)",
      "ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl_usr_rule"
    )

    execute(
      "ALTER TABLE rules
        ADD CONSTRAINT destination_overlap_excl_port EXCLUDE USING gist (destination inet_ops WITH &&, action WITH =, port_range WITH &&, port_type WITH =) WHERE (user_id IS NULL AND port_range IS NOT NULL)",
      "ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl_rule_port"
    )

    execute(
      "ALTER TABLE rules
        ADD CONSTRAINT destination_overlap_excl_usr_rule_port EXCLUDE USING gist (destination inet_ops WITH &&, user_id WITH =, action WITH =, port_range WITH &&, port_type WITH =) WHERE (user_id IS NOT NULL AND port_range IS NOT NULL)",
      "ALTER TABLE rules DROP CONSTRAINT destination_overlap_excl_usr_rule_port"
    )
  end
end
