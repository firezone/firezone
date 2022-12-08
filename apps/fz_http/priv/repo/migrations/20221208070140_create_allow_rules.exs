defmodule FzHttp.Repo.Migrations.CreateAllowRules do
  use Ecto.Migration

  @create_enum_query "CREATE TYPE protocol_enum AS ENUM ('tcp', 'udp')"
  @drop_enum_query "DROP TYPE protocol_enum"

  def change do
    execute(@create_enum_query, @drop_enum_query)

    create table("allow_rules", primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:destination, :inet, null: false)
      add(:gateway_id, :uuid, null: false)
      add(:user_id, :uuid, default: nil)
      add(:port_range_start, :integer, default: nil)
      add(:port_range_end, :integer, default: nil)
      add(:protocol, :protocol_enum, default: nil)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:allow_rules, :gateway_id))
    create(index(:allow_rules, :user_id))

    create(
      constraint("allow_rules", :port_range_is_within_valid_values,
        check: "int4range(port_range_start, port_range_end) <@ int4range(1, 65535)"
      )
    )

    create(
      constraint("allow_rules", :optional_port_range_protocol,
        check: """
        port_range_start IS NOT NULL AND port_range_end IS NOT NULL OR
        protocol IS NULL AND port_range_start IS NULL AND port_range_end IS NULL
        """
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION notify_allow_rule_changes()
    RETURNS trigger AS $$
    DECLARE
      row record;
    BEGIN
      row := NEW;

      IF (TG_OP = 'DELETE') THEN
        row := OLD;
      END IF;

      PERFORM pg_notify(
        'allow_rules_changed',
        json_build_object(
          'op', TG_OP,
          'row', row_to_json(row)
        )::text
      );
      RETURN row;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER allow_rules_changed
    AFTER INSERT OR DELETE OR UPDATE ON allow_rules
    DEFERRABLE
    FOR EACH ROW EXECUTE PROCEDURE notify_allow_rule_changes()
    """)
  end
end
