defmodule FzHttp.Repo.Migrations.CreateNetworkPolicies do
  use Ecto.Migration

  @create_default_action_query "CREATE TYPE default_action_enum AS ENUM ('accept', 'deny')"
  @drop_default_action_query "DROP TYPE default_action_enum"
  @create_protocol_query "CREATE TYPE protocol_enum AS ENUM ('tcp', 'udp')"
  @drop_protocol_query "DROP TYPE protocol_enum"

  def change do
    execute(@create_default_action_query, @drop_default_action_query)
    execute(@create_protocol_query, @drop_protocol_query)

    create table(:network_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:user_id, references(:users, column: :uuid, type: :uuid))
      add(:default_action, :default_action_enum, default: "deny", null: false)
      add(:destination, :inet, null: false)
      add(:port_range_start, :integer)
      add(:port_range_end, :integer)
      add(:protocol, :protocol_enum)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint("network_policies", :port_range_is_within_valid_values,
        check: "int4range(port_range_start, port_range_end) <@ int4range(1, 65535)"
      )
    )

    create(
      constraint("network_policies", :optional_port_range_protocol,
        check: """
        port_range_start IS NOT NULL AND port_range_end IS NOT NULL OR
        protocol IS NULL AND port_range_start IS NULL AND port_range_end IS NULL
        """
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION notify_network_policy_changes()
    RETURNS trigger AS $$
    DECLARE
      row record;
    BEGIN
      row := NEW;

      IF (TG_OP = 'DELETE') THEN
        row := OLD;
      END IF;

      PERFORM pg_notify(
        'network_policies_changed',
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
    CREATE CONSTRAINT TRIGGER network_policies_changed
    AFTER INSERT OR DELETE OR UPDATE ON network_policies
    DEFERRABLE
    FOR EACH ROW EXECUTE PROCEDURE notify_network_policy_changes()
    """)
  end
end
