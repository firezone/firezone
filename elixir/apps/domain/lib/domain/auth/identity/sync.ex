defmodule Domain.Auth.Identity.Sync do
  alias Domain.Actors
  alias Domain.Auth.{Identity, Provider}

  def sync_provider_identities_multi(%Provider{} = provider, attrs_list) do
    now = DateTime.utc_now()

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
    |> Ecto.Multi.update_all(
      :delete_identities,
      fn %{plan_identities: {_insert, _update, delete}} ->
        delete_identities_query(provider, delete)
      end,
      set: [deleted_at: now]
    )
    |> Ecto.Multi.run(
      :insert_identities,
      fn repo, %{plan_identities: {insert, _update, _delete}} ->
        upsert_identities(repo, provider, attrs_by_provider_identifier, insert)
      end
    )
    |> Ecto.Multi.run(
      :sync_actors,
      fn _repo, %{identities: identities, plan_identities: {_insert, update, _delete}} ->
        sync_actors(identities, attrs_by_provider_identifier, update)
      end
    )
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

  defp delete_identities_query(provider, provider_identifiers_to_delete) do
    Identity.Query.by_account_id(provider.account_id)
    |> Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.by_provider_identifier({:in, provider_identifiers_to_delete})
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

  defp sync_actors(
         identities,
         attrs_by_provider_identifier,
         provider_identifiers_to_insert
       ) do
    identity_by_provider_identifier = Map.new(identities, &{&1.provider_identifier, &1})

    provider_identifiers_to_insert
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      attrs = Map.get(attrs_by_provider_identifier, provider_identifier)
      identity = Map.get(identity_by_provider_identifier, provider_identifier)

      if actor_attrs = Map.get(attrs, "actor", %{}) do
        case Actors.sync_actor(identity.actor_id, actor_attrs) do
          {:ok, actor} ->
            {:cont, {:ok, [actor | acc]}}

          {:error, changeset} ->
            {:halt, {:error, changeset}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end
end
