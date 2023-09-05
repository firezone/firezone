defmodule Domain.Actors.Membership.Sync do
  alias Domain.Auth
  alias Domain.Actors.Membership

  def sync_provider_memberships_multi(multi, %Auth.Provider{} = provider, tuples) do
    multi
    |> Ecto.Multi.all(:memberships, fn _effects_so_far ->
      fetch_and_lock_provider_memberships_query(provider)
    end)
    |> Ecto.Multi.run(
      :plan_memberships,
      fn _repo,
         %{
           actor_ids_by_provider_identifier: actor_ids_by_provider_identifier,
           group_ids_by_provider_identifier: group_ids_by_provider_identifier,
           memberships: memberships
         } ->
        tuples =
          Enum.map(tuples, fn {group_provider_identifier, actor_provider_identifier} ->
            {Map.fetch!(group_ids_by_provider_identifier, group_provider_identifier),
             Map.fetch!(actor_ids_by_provider_identifier, actor_provider_identifier)}
          end)

        plan_memberships_update(tuples, memberships)
      end
    )
    |> Ecto.Multi.delete_all(:delete_memberships, fn %{plan_memberships: {_upsert, delete}} ->
      delete_memberships_query(delete)
    end)
    |> Ecto.Multi.run(:upsert_memberships, fn repo, %{plan_memberships: {upsert, _delete}} ->
      upsert_memberships(repo, provider, upsert)
    end)
  end

  defp fetch_and_lock_provider_memberships_query(provider) do
    Membership.Query.by_account_id(provider.account_id)
    |> Membership.Query.by_group_provider_id(provider.id)
    |> Membership.Query.lock()
  end

  defp plan_memberships_update(tuples, memberships) do
    {upsert, delete} =
      Enum.reduce(
        memberships,
        {tuples, []},
        fn membership, {upsert, delete} ->
          tuple = {membership.group_id, membership.actor_id}

          if tuple in tuples do
            {upsert, delete}
          else
            {upsert -- [tuple], [tuple] ++ delete}
          end
        end
      )

    {:ok, {upsert, delete}}
  end

  defp delete_memberships_query(provider_identifiers_to_delete) do
    Membership.Query.by_group_id_and_actor_id({:in, provider_identifiers_to_delete})
  end

  defp upsert_memberships(repo, provider, provider_identifiers_to_upsert) do
    provider_identifiers_to_upsert
    |> Enum.reduce_while({:ok, []}, fn {group_id, actor_id}, {:ok, acc} ->
      attrs = %{group_id: group_id, actor_id: actor_id}

      case upsert_membership(repo, provider, attrs) do
        {:ok, membership} ->
          {:cont, {:ok, [membership | acc]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp upsert_membership(repo, provider, attrs) do
    Membership.Changeset.upsert(provider.account_id, %Membership{}, attrs)
    |> repo.insert(
      conflict_target: Membership.Changeset.upsert_conflict_target(),
      on_conflict: Membership.Changeset.upsert_on_conflict(),
      returning: true
    )
  end
end
