defmodule Domain.Actors.Group.Sync do
  alias Domain.Repo
  alias Domain.Auth
  alias Domain.Actors
  alias Domain.Actors.Group

  def sync_provider_groups(%Auth.Provider{} = provider, attrs_list) do
    attrs_by_provider_identifier =
      for attrs <- attrs_list, into: %{} do
        {Map.fetch!(attrs, "provider_identifier"), attrs}
      end

    provider_identifiers = Map.keys(attrs_by_provider_identifier)

    # We always want to keep our DB groups in sync with all provider groups, regardless of filtering.
    # However, if the provider has group filteres enabled, we only want to return provider identifiers
    # that are included so that memberships and identities can be filtered accordingly.
    with {:ok, groups} <- all_provider_groups(provider),
         {:ok, {upsert, delete}} <- plan_groups_update(groups, provider_identifiers),
         {:ok, deleted} <- delete_groups(provider, delete),
         {:ok, upserted} <- upsert_groups(provider, attrs_by_provider_identifier, upsert) do
      group_ids_by_provider_identifier =
        for group <- groups ++ upserted,
            group.provider_identifier not in delete,
            # Apply group filters if they are enabled
            is_nil(provider.group_filters_enabled_at) or group.provider_identifier in provider.included_groups,
            into: %{} do
          {group.provider_identifier, group.id}
        end

      {:ok,
       %{
         plan: {upsert, delete},
         deleted: deleted,
         upserted: upserted,
         group_ids_by_provider_identifier: group_ids_by_provider_identifier
       }}
    end
  end

  defp all_provider_groups(provider) do
    # includes excluded - we want to include them for sync purposes
    groups =
      Group.Query.not_deleted()
      |> Group.Query.by_account_id(provider.account_id)
      |> Group.Query.by_provider_id(provider.id)
      |> Repo.all()

    {:ok, groups}
  end

  defp plan_groups_update(groups, provider_identifiers) do
    {upsert, delete} =
      Enum.reduce(groups, {provider_identifiers, []}, fn group, {upsert, delete} ->
        if group.provider_identifier in provider_identifiers do
          {upsert, delete}
        else
          {upsert -- [group.provider_identifier], [group.provider_identifier] ++ delete}
        end
      end)

    {:ok, {upsert, delete}}
  end

  defp delete_groups(provider, provider_identifiers_to_delete) do
    # includes excluded - we want to mark them deleted for sync purposes
    Group.Query.not_deleted()
    |> Group.Query.by_account_id(provider.account_id)
    |> Group.Query.by_provider_id(provider.id)
    |> Group.Query.by_provider_identifier({:in, provider_identifiers_to_delete})
    |> Actors.delete_groups()
  end

  defp upsert_groups(provider, attrs_by_provider_identifier, provider_identifiers_to_upsert) do
    provider_identifiers_to_upsert
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      attrs = Map.get(attrs_by_provider_identifier, provider_identifier)
      attrs = Map.put(attrs, "type", :managed)

      case upsert_group(Repo, provider, attrs) do
        {:ok, group} ->
          {:cont, {:ok, [group | acc]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp upsert_group(repo, provider, attrs) do
    Group.Changeset.create(provider, attrs)
    |> repo.insert(
      conflict_target: Group.Changeset.upsert_conflict_target(),
      on_conflict: Group.Changeset.upsert_on_conflict(),
      returning: true
    )
  end
end
