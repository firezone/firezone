defmodule Portal.Repo.Migrations.DropDuplicateAccountIdIdIndexes do
  @moduledoc """
  Drops the `(account_id, id)` unique indexes on `groups`, `resources` and
  `sites`. They are byte-for-byte copies of those tables' primary keys.

  `20251206030629_composite_primary_keys` widened the primary keys to
  `(account_id, id)`, which turned the older standalone unique indexes into
  copies. `20251206043744_simplify_all_indexes` was meant to drop them, but its
  `up/0` builds a list of SQL strings and never runs them, so it did nothing and
  the copies are still there.

  Each copy is older than its primary key, so it has the lower OID, and that is
  the one Postgres picked to back the foreign keys pointing at the table.
  `DROP INDEX` fails while a foreign key depends on the index, so each key has
  to be dropped first; a key added back afterwards binds to the primary key
  instead. The drops, the index drop and the re-adds run in one `DO` block so a
  failure anywhere leaves every foreign key in place.

  The keys come back `NOT VALID` and are validated in separate statements, which
  keeps the validation scan from blocking writes. The rows were already valid a
  moment earlier and the block enforces the key again for every new write, so
  nothing can slip past.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @duplicates [
    %{
      table: "groups",
      index: "groups_account_id_id_index",
      foreign_keys: [
        {"group_sync_states", "group_sync_states_group_id_fkey",
         "FOREIGN KEY (group_id, account_id) REFERENCES groups (id, account_id) ON DELETE CASCADE"},
        {"memberships", "memberships_group_id_fkey",
         "FOREIGN KEY (account_id, group_id) REFERENCES groups (account_id, id) ON DELETE CASCADE"},
        {"policies", "policies_group_id_fkey",
         "FOREIGN KEY (account_id, group_id) REFERENCES groups (account_id, id) ON DELETE SET NULL (group_id)"}
      ]
    },
    %{
      table: "resources",
      index: "resources_account_id_id_index",
      foreign_keys: [
        {"policies", "policies_resource_id_fkey",
         "FOREIGN KEY (account_id, resource_id) REFERENCES resources (account_id, id) ON DELETE CASCADE"},
        {"policy_authorizations", "policy_authorizations_resource_id_fkey",
         "FOREIGN KEY (account_id, resource_id) REFERENCES resources (account_id, id) ON DELETE CASCADE"},
        {"static_device_pool_members", "static_device_pool_members_resource_id_fkey",
         "FOREIGN KEY (resource_id, account_id) REFERENCES resources (id, account_id) ON DELETE CASCADE"}
      ]
    },
    %{
      table: "sites",
      index: "sites_account_id_id_index",
      foreign_keys: [
        {"devices", "devices_site_id_fkey",
         "FOREIGN KEY (account_id, site_id) REFERENCES sites (account_id, id) ON DELETE CASCADE"},
        {"gateway_tokens", "gateway_tokens_site_id_fkey",
         "FOREIGN KEY (account_id, site_id) REFERENCES sites (account_id, id) ON DELETE CASCADE"},
        {"resources", "resources_site_id_fkey",
         "FOREIGN KEY (account_id, site_id) REFERENCES sites (account_id, id) ON DELETE CASCADE"}
      ]
    }
  ]

  def up do
    for %{index: index, foreign_keys: foreign_keys} <- @duplicates do
      execute(rebind_to_primary_key(index, foreign_keys))

      for {table, constraint, _definition} <- foreign_keys do
        execute("ALTER TABLE #{table} VALIDATE CONSTRAINT #{constraint}")
      end
    end
  end

  def down do
    for %{table: table, index: index} <- @duplicates do
      create_if_not_exists(
        unique_index(table, [:account_id, :id], name: index, concurrently: true)
      )
    end
  end

  defp rebind_to_primary_key(index, foreign_keys) do
    drops =
      Enum.map_join(foreign_keys, "\n", fn {table, constraint, _definition} ->
        "  ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{constraint};"
      end)

    adds =
      Enum.map_join(foreign_keys, "\n", fn {table, constraint, definition} ->
        "  ALTER TABLE #{table} ADD CONSTRAINT #{constraint} #{definition} NOT VALID;"
      end)

    """
    DO $$
    BEGIN
      IF to_regclass('public.#{index}') IS NULL THEN
        RETURN;
      END IF;

    #{drops}

      DROP INDEX #{index};

    #{adds}
    END
    $$
    """
  end
end
