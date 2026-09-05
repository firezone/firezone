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
  """
  alias __MODULE__.Database

  defdelegate batch_upsert_identities(
                account_id,
                issuer,
                directory_id,
                synced_at,
                attrs,
                extra_fields
              ),
              to: Database

  defdelegate batch_upsert_groups(account_id, directory_id, synced_at, attrs, entity_type),
    to: Database

  defdelegate batch_upsert_memberships(account_id, issuer, directory_id, synced_at, tuples),
    to: Database

  defdelegate remove_identity(account_id, directory_id, identity, synced_at), to: Database
  defdelegate remove_group(account_id, directory_id, group, synced_at), to: Database
  defdelegate stamp_identity_memberships(account_id, directory_id, idp_id, synced_at), to: Database
  defdelegate delete_unsynced_identities(account_id, directory_id, synced_at), to: Database
  defdelegate delete_unsynced_groups(account_id, directory_id, synced_at), to: Database
  defdelegate delete_unsynced_memberships(account_id, directory_id, synced_at), to: Database
  defdelegate delete_actors_without_identities(account_id, directory_id), to: Database
  defdelegate prune_tombstones(account_id, directory_id, before), to: Database
end
