defmodule Portal.Repo.Migrations.NameFlowLogSides do
  use Ecto.Migration

  @moduledoc """
  Names both sides of a flow explicitly instead of leaving one column relative
  to whichever device reported the row.

  Every other column is oriented from the initiator: connlib normalizes the
  inner and outer tuples to (initiator-src, responder-dst) and defines tx as
  initiator-to-responder on both sides, so an initiator row and a responder row
  of the same flow carry identical tuples and counters. `device_id` was the one
  exception: it held the reporting device, so the same column meant the
  initiating Client on one row and the Gateway (or receiving Client) on the
  other. It shared its `device_` prefix with six telemetry columns that always
  described the initiating Client, so a responder row read as a Gateway
  carrying an end user's laptop serial.

  `device_id` becomes `initiator_device_id` and the responder gains a column of
  its own, so every row names both endpoints without a join. Both are known
  when the authorization is minted (they are the same two values as
  `policy_authorizations.initiating_device_id` / `receiving_device_id`), so
  both tokens carry both. `role` keeps its name and values: with the columns
  prefixed, `role = 'responder'` now points at `responder_device_id` by name.

  The initiator-only telemetry and the actor snapshot take an `initiator_`
  prefix for the same reason. The actor is the initiating Client's actor, which
  is unambiguous for Gateway flows but not for device-to-device flows, where
  the receiving Client has an owner of its own that this row does not record.

  This is a manual migration: it is gated by `run_manual_migrations`, and all
  but two of the columns it renames were added by the manual
  20260619000000_reshape_flow_logs, so it has to run in that same sequence.

  Renames are catalog-only and recurse to the partitions. The primary key
  covers `device_id`, but the rename carries it along and no index name embeds
  a renamed column, so nothing is rebuilt. `responder_device_id` is added NOT
  NULL without a default, which Postgres only allows because flow_logs is empty
  in every environment (ingestion has not launched).
  """

  def change do
    rename(table(:flow_logs), :device_id, to: :initiator_device_id)

    alter table(:flow_logs) do
      add(:responder_device_id, :binary_id, null: false)
    end

    rename(table(:flow_logs), :client_version, to: :initiator_client_version)
    rename(table(:flow_logs), :device_os_name, to: :initiator_device_os_name)
    rename(table(:flow_logs), :device_os_version, to: :initiator_device_os_version)
    rename(table(:flow_logs), :device_serial, to: :initiator_device_serial)
    rename(table(:flow_logs), :device_uuid, to: :initiator_device_uuid)

    rename(table(:flow_logs), :device_identifier_for_vendor,
      to: :initiator_device_identifier_for_vendor
    )

    rename(table(:flow_logs), :device_firebase_installation_id,
      to: :initiator_device_firebase_installation_id
    )

    rename(table(:flow_logs), :actor_id, to: :initiator_actor_id)
    rename(table(:flow_logs), :actor_email, to: :initiator_actor_email)
    rename(table(:flow_logs), :actor_name, to: :initiator_actor_name)
    rename(table(:flow_logs), :auth_provider_id, to: :initiator_auth_provider_id)
  end
end
