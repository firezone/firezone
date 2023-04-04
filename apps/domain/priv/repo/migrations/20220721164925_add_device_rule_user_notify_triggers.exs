defmodule Domain.Repo.Migrations.AddDeviceRuleUserNotifyTriggers do
  use Ecto.Migration

  def change do
    for table <- ["devices", "rules", "users"] do
      func = String.trim_trailing(table, "s")

      execute("""
      CREATE OR REPLACE FUNCTION notify_#{func}_changes()
      RETURNS trigger AS $$
      DECLARE
        row record;
      BEGIN
        row := NEW;

        IF (TG_OP = 'DELETE') THEN
          row := OLD;
        END IF;

        PERFORM pg_notify(
          '#{table}_changed',
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
      CREATE CONSTRAINT TRIGGER #{table}_changed
      AFTER INSERT OR DELETE ON #{table}
      DEFERRABLE
      FOR EACH ROW EXECUTE PROCEDURE notify_#{func}_changes()
      """)
    end
  end
end
