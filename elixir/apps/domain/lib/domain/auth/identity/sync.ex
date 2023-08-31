defmodule Domain.Auth.Identity.Sync do
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
      fn %{plan_identities: {_insert, delete}} ->
        delete_identities_query(provider, delete)
      end,
      set: [deleted_at: now]
    )
    |> Ecto.Multi.run(:insert_identities, fn repo, %{plan_identities: {insert, _delete}} ->
      upsert_identities(repo, provider, attrs_by_provider_identifier, insert)
    end)
  end

  defp fetch_and_lock_provider_identities_query(provider) do
    Identity.Query.by_account_id(provider.account_id)
    |> Identity.Query.by_provider_id(provider.id)
    |> Identity.Query.lock()
  end

  defp plan_identities_update(identities, provider_identifiers) do
    {insert, delete} =
      Enum.reduce(identities, {provider_identifiers, []}, fn identity, {insert, delete} ->
        if identity.provider_identifier in provider_identifiers do
          {insert -- [identity.provider_identifier], delete}
        else
          {insert -- [identity.provider_identifier], [identity.provider_identifier] ++ delete}
        end
      end)

    {:ok, {insert, delete}}
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
end
