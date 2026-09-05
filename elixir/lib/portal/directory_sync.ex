defmodule Portal.DirectorySync do
  @moduledoc """
  Writes shared by the Entra, Google, and Okta syncs and their webhook workers.

  Every write carries a timestamp: a full sync uses its start time for the
  whole run, a webhook job uses the moment it re-read the object. A write first
  claims the directory-keyed state row of each identity or group, and it
  touches the entity only where the claim won, so the newest write always
  wins no matter which one reaches the database first. Deletes keep the
  state row as a tombstone, and a rewrite of a membership list stamps the
  group or user it belongs to, which blocks older membership writes even for
  rows the database never had. Postgres serializes competing claims on the
  state row itself, so no lock is held across a sync.

  Freshness is not the same as eligibility. Only a listing that proves a user
  belongs in the directory, a full sync or a group resync after the group's
  app assignment was checked, marks the user eligible, and the full sync
  cleanup removes everything that no such listing confirmed during the run.
  """
  alias __MODULE__.Database

  defdelegate batch_upsert_identities(account_id, issuer, directory_id, synced_at, attrs, opts),
    to: Database

  defdelegate batch_upsert_groups(account_id, directory_id, synced_at, attrs, entity_type),
    to: Database

  defdelegate batch_upsert_memberships(account_id, issuer, directory_id, synced_at, tuples),
    to: Database

  defdelegate remove_identity(account_id, directory_id, issuer, idp_id, synced_at), to: Database
  defdelegate remove_group(account_id, directory_id, idp_id, synced_at), to: Database

  defdelegate stamp_identity_org_unit_memberships(account_id, directory_id, idp_id, synced_at),
    to: Database

  defdelegate delete_unsynced_identities(account_id, directory_id, synced_at), to: Database
  defdelegate delete_unsynced_groups(account_id, directory_id, synced_at), to: Database
  defdelegate delete_unsynced_memberships(account_id, directory_id, synced_at), to: Database
  defdelegate delete_actors_without_identities(account_id, directory_id), to: Database
  defdelegate prune_tombstones(account_id, directory_id, previous_run_started_at), to: Database
  defdelegate full_sync_running?(worker, directory_id), to: Database
  defdelegate tombstone_grace_seconds(), to: Database
end
