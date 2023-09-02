defmodule Domain.Actors.Group.Sync do
  alias Domain.Auth
  alias Domain.Actors.Group

  def sync_provider_groups_multi(%Auth.Provider{} = provider, attrs_list) do
    now = DateTime.utc_now()

    attrs_by_provider_identifier =
      for attrs <- attrs_list, into: %{} do
        {Map.fetch!(attrs, "provider_identifier"), attrs}
      end

    Ecto.Multi.new()
    |> Ecto.Multi.all(:groups, fn _effects_so_far ->
      fetch_and_lock_provider_groups_query(provider)
    end)
    |> Ecto.Multi.run(:plan_groups, fn _repo, %{groups: groups} ->
      plan_groups_update(groups, attrs_by_provider_identifier)
    end)
    |> Ecto.Multi.update_all(
      :delete_groups,
      fn %{plan_groups: {_upsert, delete}} ->
        delete_groups_query(provider, delete)
      end,
      set: [deleted_at: now]
    )
    |> Ecto.Multi.run(:upsert_groups, fn repo, %{plan_groups: {upsert, _delete}} ->
      upsert_groups(repo, provider, attrs_by_provider_identifier, upsert)
    end)
  end

  defp fetch_and_lock_provider_groups_query(provider) do
    Group.Query.by_account_id(provider.account_id)
    |> Group.Query.by_provider_id(provider.id)
    |> Group.Query.lock()
  end

  defp plan_groups_update(groups, attrs_by_provider_identifier) do
    {update, delete} =
      Enum.reduce(groups, {[], []}, fn group, {update, delete} ->
        if Map.has_key?(attrs_by_provider_identifier, group.provider_identifier) do
          {[group.provider_identifier] ++ update, delete}
        else
          {update, [group.provider_identifier] ++ delete}
        end
      end)

    insert = Map.keys(attrs_by_provider_identifier) -- (update ++ delete)

    {:ok, {update ++ insert, delete}}
  end

  defp delete_groups_query(provider, provider_identifiers_to_delete) do
    Group.Query.by_account_id(provider.account_id)
    |> Group.Query.by_provider_id(provider.id)
    |> Group.Query.by_provider_identifier({:in, provider_identifiers_to_delete})
  end

  defp upsert_groups(repo, provider, attrs_by_provider_identifier, provider_identifiers_to_upsert) do
    provider_identifiers_to_upsert
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      attrs = Map.get(attrs_by_provider_identifier, provider_identifier)

      case upsert_group(repo, provider, attrs) do
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
