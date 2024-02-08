defmodule Domain.Auth.Identity.Sync do
  alias Domain.Auth.{Identity, Provider}

  def sync_provider_identities_multi(%Provider{} = provider, attrs_list) do
    attrs_by_provider_identifier =
      for attrs <- attrs_list, into: %{} do
        {Map.fetch!(attrs, "provider_identifier"), attrs}
      end

    provider_identifiers = Map.keys(attrs_by_provider_identifier)

    Ecto.Multi.new()
    |> Ecto.Multi.all(:identities, fn _effects_so_far ->
      fetch_and_lock_provider_identities_query(provider)
    end)
    |> Ecto.Multi.run(:plan_identities, fn _repo, %{identities: identities} ->
      plan_identities_update(identities, provider_identifiers)
    end)
    |> Ecto.Multi.run(
      :delete_identities,
      fn repo, %{plan_identities: {_insert, _update, delete}} ->
        delete_identities(repo, provider, delete)
      end
    )
    |> Ecto.Multi.run(
      :insert_identities,
      fn repo, %{plan_identities: {insert, _update, _delete}} ->
        upsert_identities(repo, provider, attrs_by_provider_identifier, insert)
      end
    )
    |> Ecto.Multi.run(
      :update_identities_and_actors,
      fn repo, %{identities: identities, plan_identities: {_insert, update, _delete}} ->
        update_identities_and_actors(repo, identities, attrs_by_provider_identifier, update)
      end
    )
    |> Ecto.Multi.run(
      :actor_ids_by_provider_identifier,
      fn _repo,
         %{
           plan_identities: {_insert, _update, delete},
           identities: identities,
           insert_identities: insert_identities
         } ->
        actor_ids_by_provider_identifier =
          for identity <- identities ++ insert_identities,
              identity.provider_identifier not in delete,
              into: %{} do
            {identity.provider_identifier, identity.actor_id}
          end

        {:ok, actor_ids_by_provider_identifier}
      end
    )
    |> Ecto.Multi.run(:recalculate_dynamic_groups, fn _repo, _effects_so_far ->
      Domain.Actors.update_dynamic_group_memberships(provider.account_id)
    end)
  end

  defp fetch_and_lock_provider_identities_query(provider) do
    Identity.Query.by_account_id(provider.account_id)
    |> Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.lock()
  end

  defp plan_identities_update(identities, provider_identifiers) do
    {insert, update, delete} =
      Enum.reduce(
        identities,
        {provider_identifiers, [], []},
        fn identity, {insert, update, delete} ->
          if identity.provider_identifier in provider_identifiers do
            {
              insert -- [identity.provider_identifier],
              [identity.provider_identifier] ++ update,
              delete
            }
          else
            {
              insert -- [identity.provider_identifier],
              update,
              [identity.provider_identifier] ++ delete
            }
          end
        end
      )

    {:ok, {insert, update, delete}}
  end

  defp delete_identities(repo, provider, provider_identifiers_to_delete) do
    {_count, identities} =
      Identity.Query.by_account_id(provider.account_id)
      |> Identity.Query.by_provider_id(provider.id)
      |> Identity.Query.by_provider_identifier({:in, provider_identifiers_to_delete})
      |> Identity.Query.delete()
      |> repo.update_all([])

    :ok =
      Enum.each(identities, fn identity ->
        {:ok, _tokens} = Domain.Tokens.delete_tokens_for(identity)
      end)

    {:ok, identities}
  end

  defp upsert_identities(
         repo,
         provider,
         attrs_by_provider_identifier,
         provider_identifiers_to_insert
       ) do
    provider_identifiers_to_insert
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      attrs = Map.get(attrs_by_provider_identifier, provider_identifier)
      changeset = Identity.Changeset.create_identity_and_actor(provider, attrs)

      case repo.insert(changeset) do
        {:ok, identity} ->
          {:cont, {:ok, [identity | acc]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp update_identities_and_actors(
         repo,
         identities,
         attrs_by_provider_identifier,
         provider_identifiers_to_update
       ) do
    identity_by_provider_identifier =
      identities
      |> Enum.filter(fn identity ->
        identity.provider_identifier in provider_identifiers_to_update
      end)
      |> repo.preload(:actor)
      |> Map.new(&{&1.provider_identifier, &1})

    provider_identifiers_to_update
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      identity = Map.get(identity_by_provider_identifier, provider_identifier)
      attrs = Map.get(attrs_by_provider_identifier, provider_identifier)
      changeset = Identity.Changeset.update_identity_and_actor(identity, attrs)

      case repo.update(changeset) do
        {:ok, identity} ->
          {:cont, {:ok, [identity | acc]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end
end
