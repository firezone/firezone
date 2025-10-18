defmodule Domain.Auth.Identity.Sync do
  alias Domain.Repo
  alias Domain.Auth.{Identity, Provider}
  require Logger

  def sync_provider_identities(%Provider{} = provider, attrs_list) do
    attrs_by_provider_identifier =
      for attrs <- attrs_list, into: %{} do
        {Map.fetch!(attrs, "provider_identifier"), attrs}
      end

    provider_identifiers = Map.keys(attrs_by_provider_identifier)

    with {:ok, identities} <- all_provider_identities(provider),
         {:ok, {insert, update, delete}} <-
           plan_identities_update(identities, provider_identifiers),
         :ok <- deletion_circuit_breaker(identities, delete, provider),
         {:ok, deleted_count} <- delete_identities(provider, delete),
         {:ok, inserted} <-
           insert_identities(provider, attrs_by_provider_identifier, insert),
         {:ok, updated} <-
           update_identities_and_actors(identities, attrs_by_provider_identifier, update) do
      Domain.Actors.update_managed_group_memberships(provider.account_id)

      actor_ids_by_provider_identifier =
        for identity <- updated ++ inserted,
            into: %{} do
          {identity.provider_identifier, identity.actor_id}
        end

      {:ok,
       %{
         identities: identities,
         plan: {insert, update, delete},
         deleted_count: deleted_count,
         inserted: inserted,
         updated: updated,
         actor_ids_by_provider_identifier: actor_ids_by_provider_identifier
       }}
    end
  end

  defp all_provider_identities(provider) do
    identities =
      Identity.Query.all()
      |> Identity.Query.by_account_id(provider.account_id)
      |> Identity.Query.by_provider_id(provider.id)
      |> Repo.all()

    {:ok, identities}
  end

  defp plan_identities_update(identities, provider_identifiers) do
    {insert, update, delete} =
      Enum.reduce(
        identities,
        {provider_identifiers, [], []},
        fn identity, {insert, update, delete} ->
          insert = insert -- [identity.provider_identifier]

          if identity.provider_identifier in provider_identifiers do
            {insert, [identity.provider_identifier] ++ update, delete}
          else
            {insert, update, [identity.provider_identifier] ++ delete}
          end
        end
      )

    {:ok, {insert, update, delete}}
  end

  # Used to make sure we don't accidentally mass delete identities
  # due to an error in the Identity Provider API (e.g. Google Admin SDK API)
  defp deletion_circuit_breaker([], _identities_to_delete, _provider) do
    # If there are no identities then there can't be anything to delete
    :ok
  end

  defp deletion_circuit_breaker(_identities, [], _provider) do
    :ok
  end

  defp deletion_circuit_breaker(identities, identities_to_delete, provider) do
    identities_length = length(identities)
    deletion_length = length(identities_to_delete)

    delete_percentage = (deletion_length / identities_length * 100) |> round()

    cond do
      identities_length > 40 and delete_percentage >= 25 ->
        Logger.error("Refusing to mass delete identities",
          identities_length: identities_length,
          deletion_length: deletion_length,
          provider_id: provider.id
        )

        {:error, "Sync deletion of identities too large"}

      identities_length <= 40 and delete_percentage >= 50 ->
        Logger.error("Refusing to mass delete identities",
          identities_length: identities_length,
          deletion_length: deletion_length,
          provider_id: provider.id
        )

        {:error, "Sync deletion of identities too large"}

      true ->
        :ok
    end
  end

  defp delete_identities(provider, provider_identifiers_to_delete) do
    {num_deleted, _} =
      Identity.Query.all()
      |> Identity.Query.by_account_id(provider.account_id)
      |> Identity.Query.by_provider_id(provider.id)
      |> Identity.Query.by_provider_identifier({:in, provider_identifiers_to_delete})
      |> Repo.delete_all()

    {:ok, num_deleted}
  end

  defp insert_identities(provider, attrs_by_provider_identifier, provider_identifiers_to_insert) do
    provider_identifiers_to_insert
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      attrs =
        Map.get(attrs_by_provider_identifier, provider_identifier)

      changeset = Identity.Changeset.create_identity_and_actor(provider, attrs)

      case Repo.insert(changeset) do
        {:ok, identity} ->
          {:cont, {:ok, [identity | acc]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp update_identities_and_actors(
         identities,
         attrs_by_provider_identifier,
         provider_identifiers_to_update
       ) do
    identity_by_provider_identifier =
      identities
      |> Enum.filter(fn identity ->
        identity.provider_identifier in provider_identifiers_to_update
      end)
      |> Repo.preload(:actor)
      |> Enum.reduce(%{}, fn identity, acc ->
        Map.put(acc, identity.provider_identifier, identity)
      end)

    provider_identifiers_to_update
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn provider_identifier, {:ok, acc} ->
      identity = Map.get(identity_by_provider_identifier, provider_identifier)
      attrs = Map.get(attrs_by_provider_identifier, provider_identifier)
      changeset = Identity.Changeset.update_identity_and_actor(identity, attrs)

      case Repo.update(changeset) do
        {:ok, identity} ->
          {:cont, {:ok, [identity | acc]}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end
end
