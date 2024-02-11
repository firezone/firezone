defmodule Domain.Actors.Group.Sync do
  alias Domain.Auth
  alias Domain.Actors
  alias Domain.Actors.Group

  def sync_provider_groups_multi(%Auth.Provider{} = provider, attrs_list) do
    attrs_by_provider_identifier =
      for attrs <- attrs_list, into: %{} do
        {Map.fetch!(attrs, "provider_identifier"), attrs}
      end

    provider_identifiers = Map.keys(attrs_by_provider_identifier)

    Ecto.Multi.new()
    |> Ecto.Multi.all(:groups, fn _effects_so_far ->
      fetch_and_lock_provider_groups_query(provider)
    end)
    |> Ecto.Multi.run(:plan_groups, fn _repo, %{groups: groups} ->
      plan_groups_update(groups, provider_identifiers)
    end)
    |> Ecto.Multi.run(
      :delete_groups,
      fn repo, %{plan_groups: {_upsert, delete}} ->
        delete_groups(repo, provider, delete)
      end
    )
    |> Ecto.Multi.run(:upsert_groups, fn repo, %{plan_groups: {upsert, _delete}} ->
      upsert_groups(repo, provider, attrs_by_provider_identifier, upsert)
    end)
    |> Ecto.Multi.run(
      :group_ids_by_provider_identifier,
      fn _repo,
         %{
           plan_groups: {_upsert, delete},
           groups: groups,
           upsert_groups: upsert_groups
         } ->
        group_ids_by_provider_identifier =
          for group <- groups ++ upsert_groups,
              group.provider_identifier not in delete,
              into: %{} do
            {group.provider_identifier, group.id}
          end

        {:ok, group_ids_by_provider_identifier}
      end
    )
  end

  defp fetch_and_lock_provider_groups_query(provider) do
    Group.Query.by_account_id(provider.account_id)
    |> Group.Query.by_provider_id(provider.id)
    |> Group.Query.lock()
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

  defp delete_groups(_repo, provider, provider_identifiers_to_delete) do
    Group.Query.by_account_id(provider.account_id)
    |> Group.Query.by_provider_id(provider.id)
    |> Group.Query.by_provider_identifier({:in, provider_identifiers_to_delete})
    |> Actors.delete_groups()
  end

  defp upsert_groups(repo, provider, attrs_by_provider_identifier, provider_identifiers_to_upsert) do
    provider_identifiers_to_upsert
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      attrs = Map.get(attrs_by_provider_identifier, provider_identifier)
      attrs = Map.put(attrs, "type", :managed)

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
