defmodule Domain.Auth.Adapters.Common.SyncLogger do
  require Logger

  # Log effects of the multi transaction
  def log_effects(provider, effects) do
    %{
      # Identities
      plan_identities: {identities_insert_ids, identities_update_ids, identities_delete_ids},
      insert_identities: identities_inserted,
      update_identities_and_actors: identities_updated,
      delete_identities: identities_deleted,
      # Groups
      plan_groups: {groups_upsert_ids, groups_delete_ids},
      upsert_groups: groups_upserted,
      delete_groups: groups_deleted,
      # Memberships
      plan_memberships: {memberships_insert_tuples, memberships_delete_tuples},
      insert_memberships: memberships_inserted,
      delete_memberships: {deleted_memberships_count, _}
    } = effects

    Logger.debug("Finished syncing provider",
      provider_id: provider.id,
      account_id: provider.account_id,
      # Identities
      plan_identities_insert: length(identities_insert_ids),
      plan_identities_update: length(identities_update_ids),
      plan_identities_delete: length(identities_delete_ids),
      identities_inserted: length(identities_inserted),
      identities_and_actors_updated: length(identities_updated),
      identities_deleted: length(identities_deleted),
      # Groups
      plan_groups_upsert: length(groups_upsert_ids),
      plan_groups_delete: length(groups_delete_ids),
      groups_upserted: length(groups_upserted),
      groups_deleted: length(groups_deleted),
      # Memberships
      plan_memberships_insert: length(memberships_insert_tuples),
      plan_memberships_delete: length(memberships_delete_tuples),
      memberships_inserted: length(memberships_inserted),
      memberships_deleted: deleted_memberships_count
    )
  end
end
