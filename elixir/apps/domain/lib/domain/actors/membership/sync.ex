defmodule Domain.Actors.Membership.Sync do
  alias Domain.Repo
  alias Domain.Auth
  alias Domain.Actors
  alias Domain.Actors.Membership

  def sync_provider_memberships(
        filtered_group_ids_by_provider_identifier,
        %Auth.Provider{} = provider,
        tuples
      ) do
    filtered_group_ids =
      Enum.flat_map(tuples, fn {group_provider_identifier, _actor_provider_identifier} ->
        group_id = Map.get(filtered_group_ids_by_provider_identifier, group_provider_identifier)

        if is_nil(group_id) do
          []
        else
          [group_id]
        end
      end)

    with {:ok, memberships} <- all_provider_memberships(provider),
         {:ok, {insert, delete}} <- plan_memberships_update(filtered_group_ids, memberships),
         deleted_stats = delete_memberships(delete),
         {:ok, inserted} <- insert_memberships(provider, insert) do
      # TODO: Don't broadcast events here until *after* the DB operation completes...
      :ok =
        Enum.each(insert, fn {group_id, actor_id} ->
          Actors.broadcast_membership_event(:create, actor_id, group_id)
        end)

      :ok =
        Enum.each(delete, fn {group_id, actor_id} ->
          Actors.broadcast_membership_event(:delete, actor_id, group_id)
        end)

      # Only report back memberships that belong to at least one kept group
      filtered_memberships =
        Enum.filter(tuples, fn {group_provider_identifier, _actor_provider_identifier} ->
          Map.has_key?(filtered_group_ids_by_provider_identifier, group_provider_identifier)
        end)

      {:ok,
       %{
         plan: {insert, delete},
         filtered_memberships: filtered_memberships,
         inserted: inserted,
         deleted_stats: deleted_stats
       }}
    end
  end

  defp all_provider_memberships(provider) do
    memberships =
      Membership.Query.by_account_id(provider.account_id)
      |> Membership.Query.by_group_provider_id(provider.id)
      |> Repo.all()

    {:ok, memberships}
  end

  defp plan_memberships_update(group_ids, memberships) do
    {insert, _update, delete} =
      Enum.reduce(
        memberships,
        {memberships, [], []},
        fn membership, {insert, update, delete} ->
          tuple = {membership.group_id, membership.actor_id}

          if membership.group_id in group_ids do
            {insert -- [tuple], [tuple] ++ update, delete}
          else
            {insert -- [tuple], update, [tuple] ++ delete}
          end
        end
      )

    {:ok, {insert, delete}}
  end

  defp delete_memberships(provider_identifiers_to_delete) do
    Membership.Query.by_group_id_and_actor_id({:in, provider_identifiers_to_delete})
    |> Repo.delete_all()
  end

  defp insert_memberships(provider, provider_identifiers_to_insert) do
    provider_identifiers_to_insert
    |> Enum.reduce_while({:ok, []}, fn {group_id, actor_id}, {:ok, acc} ->
      attrs = %{group_id: group_id, actor_id: actor_id}

      case upsert_membership(provider, attrs) do
        {:ok, membership} ->
          {:cont, {:ok, [membership | acc]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp upsert_membership(provider, attrs) do
    Membership.Changeset.upsert(provider.account_id, %Membership{}, attrs)
    |> Repo.insert(
      conflict_target: Membership.Changeset.upsert_conflict_target(),
      on_conflict: Membership.Changeset.upsert_on_conflict(),
      returning: true
    )
  end
end
