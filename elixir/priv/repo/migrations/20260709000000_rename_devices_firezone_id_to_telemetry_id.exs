defmodule Portal.Repo.Migrations.RenameDevicesFirezoneIdToTelemetryId do
  @moduledoc """
  The id reported by a client or gateway is a telemetry hint, not an identity:
  single-owner tokens identify gateways directly, so the column is renamed to
  what it actually represents. External surfaces (the FIREZONE_ID env var and
  the external_id/firezone_id API field names) keep their names.
  """
  use Ecto.Migration

  def up do
    rename(table(:devices), :firezone_id, to: :telemetry_id)

    execute("""
    ALTER INDEX devices_account_id_actor_id_firezone_id_index
    RENAME TO devices_account_id_actor_id_telemetry_id_index
    """)

    execute("""
    ALTER INDEX devices_account_id_site_id_firezone_id_index
    RENAME TO devices_account_id_site_id_telemetry_id_index
    """)
  end

  def down do
    execute("""
    ALTER INDEX devices_account_id_site_id_telemetry_id_index
    RENAME TO devices_account_id_site_id_firezone_id_index
    """)

    execute("""
    ALTER INDEX devices_account_id_actor_id_telemetry_id_index
    RENAME TO devices_account_id_actor_id_firezone_id_index
    """)

    rename(table(:devices), :telemetry_id, to: :firezone_id)
  end
end
