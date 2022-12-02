defmodule FzHttp.Repo.Migrations.CreateGatewayFirewallPolicies do
  use Ecto.Migration

  @create_query "CREATE TYPE protocol_enum AS ENUM ('tcp', 'udp')"
  @drop_query "DROP TYPE protocol_enum"

  def change do
    execute(@create_query, @drop_query)

    create table(:gateway_firewall_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:gateway_id, references(:gateways, on_delete: :delete_all, type: :uuid), null: false)
      add(:user_id, references(:users, column: :uuid, type: :uuid))
      add(:destination, :inet, null: false)
      add(:port_range_start, :integer)
      add(:port_range_end, :integer)
      add(:protocol, :protocol_enum)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint("gateway_firewall_policies", :port_range_is_within_valid_values,
        check: "int4range(port_range_start, port_range_end) <@ int4range(1, 65535)"
      )
    )

    create(
      constraint("gateway_firewall_policies", :port_range_has_optional_protocol,
        check: """
        port_range_start IS NOT NULL AND port_range_end IS NOT NULL AND protocol is NOT NULL
        OR protocol IS NULL
        """
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION notify_gateway_firewall_policy_changes()
    RETURNS trigger AS $$
    DECLARE
      row record;
    BEGIN
      row := NEW;

      IF (TG_OP = 'DELETE') THEN
        row := OLD;
      END IF;

      PERFORM pg_notify(
        'gateway_firewall_policies_changed',
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
    CREATE CONSTRAINT TRIGGER gateway_firewall_policies_changed
    AFTER INSERT OR DELETE OR UPDATE ON gateway_firewall_policies
    DEFERRABLE
    FOR EACH ROW EXECUTE PROCEDURE notify_gateway_firewall_policy_changes()
    """)

    create(index(:gateway_firewall_policies, [:gateway_id]))
    create(index(:gateway_firewall_policies, [:user_id]))
  end
end
