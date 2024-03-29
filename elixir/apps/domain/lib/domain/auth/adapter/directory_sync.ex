defmodule Domain.Auth.Adapter.DirectorySync do
  alias Domain.Repo
  alias Domain.{Auth, Actors}
  require Logger

  @doc """
  Returns a tuple with the data needed to sync all entities of the provider.

  Must return a tuple with the following structure:

  {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}}

  Where:

  `identities_attrs` is a list of `Auth.Provider.Identity` attribute maps:

      %{
        "provider_identifier" => String.t(),
        "provider_state" => %{
          "userinfo" => %{
            "email" => String.t()
          }
        },
        "actor" => %{
          "type" => atom(),
          "name" => String.t()
        }
      }

  `actor_groups_attrs` is a list of `Auth.Actor.Group` attribute maps:

      %{
        "name" => String.t(),
        "provider_identifier" => String.t()
      }

  `membership_tuples` is a list of tuples that represent the memberships between groups and identities:

      {
        group_provider_identifier :: String.t(),
        identity_provider_identifier :: String.t()
      }

  The function can also return an error tuple with the following structure:

    - `{:error, {:unauthorized, user_message}}` - when the user is not authorized to sync the provider;
    - `{:error, user_message, log_message}` - when an error occurred during the data gathering process.

  Where `user_message` user message will be rendered in the UI and `log_message` will be logged with
  a level that corresponds to number of retries (see `log_sync_error/2`).
  """
  @callback gather_provider_data(%Auth.Provider{}) ::
              {:ok,
               {
                 identities_attrs :: [
                   map()
                 ],
                 actor_groups_attrs :: [
                   map()
                 ],
                 membership_tuples :: [
                   {
                     group_provider_identifier :: String.t(),
                     identity_provider_identifier :: String.t()
                   }
                 ]
               }}
              | {:error, {:unauthorized, user_message :: String.t()}}
              | {:error, user_message :: String.t(), log_message :: String.t()}

  def sync_providers(module, providers) do
    providers
    |> Domain.Repo.preload(:account)
    |> Enum.each(&sync_provider(module, &1))
  end

  defp sync_provider(module, provider) do
    Logger.debug("Syncing provider",
      account_id: provider.account_id,
      provider_id: provider.id,
      provider_adapter: provider.adapter
    )

    with true <- Domain.Accounts.idp_sync_enabled?(provider.account),
         {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}} <-
           module.gather_provider_data(provider) do
      Ecto.Multi.new()
      |> Ecto.Multi.one(:lock_provider, fn _effects_so_far ->
        Auth.Provider.Query.not_disabled()
        |> Auth.Provider.Query.by_account_id(provider.account_id)
        |> Auth.Provider.Query.by_id(provider.id)
        |> Auth.Provider.Query.lock()
      end)
      |> Ecto.Multi.append(Auth.sync_provider_identities_multi(provider, identities_attrs))
      |> Ecto.Multi.append(Actors.sync_provider_groups_multi(provider, actor_groups_attrs))
      |> Actors.sync_provider_memberships_multi(provider, membership_tuples)
      |> Ecto.Multi.update(:save_last_updated_at, fn _effects_so_far ->
        Auth.Provider.Changeset.sync_finished(provider)
      end)
      |> Repo.transaction(timeout: :timer.minutes(30))
      |> case do
        {:ok, effects} ->
          log_sync_result(provider, effects)
          :ok

        {:error, reason} ->
          log_sync_error(
            provider,
            "Repo error: " <> inspect(reason)
          )

        {:error, step, reason, _effects_so_far} ->
          log_sync_error(
            provider,
            "Multi error at step " <> inspect(step) <> ": " <> inspect(reason)
          )
      end
    else
      false ->
        message = "IdP sync is not enabled in your subscription plan"

        Auth.Provider.Changeset.sync_failed(provider, message)
        |> Domain.Repo.update!()

      {:error, {:unauthorized, user_message}} ->
        Auth.Provider.Changeset.sync_requires_manual_intervention(provider, user_message)
        |> Domain.Repo.update!()

      {:error, nil, log_message} ->
        log_sync_error(provider, log_message)

      {:error, user_message, log_message} ->
        Auth.Provider.Changeset.sync_failed(provider, user_message)
        |> Domain.Repo.update!()
        |> log_sync_error(log_message)
    end
  end

  defp log_sync_result(provider, effects) do
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
      provider_adapter: provider.adapter,
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

  defp log_sync_error(provider, message) do
    metadata = [
      account_id: provider.account_id,
      provider_id: provider.id,
      provider_adapter: provider.adapter,
      reason: message
    ]

    cond do
      provider.last_syncs_failed >= 100 ->
        Logger.error("Failed to sync provider", metadata)

      provider.last_syncs_failed >= 3 ->
        Logger.warning("Failed to sync provider", metadata)

      true ->
        Logger.info("Failed to sync provider", metadata)
    end
  end

  def run_async_requests(supervisor, callbacks) do
    opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()
    opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
    metadata = Logger.metadata()
    caller_pid = self()

    callbacks
    |> Enum.map(fn {name, callback} ->
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Logger.metadata(metadata)
          Process.put(:last_caller_pid, caller_pid)
          OpenTelemetry.Ctx.attach(opentelemetry_ctx)
          OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)
          callback.()
        end)

      {name, task}
    end)
    |> Enum.reduce({:ok, %{}}, fn
      {_name, task}, {:error, reason} ->
        Task.Supervisor.terminate_child(supervisor, task.pid)
        {:error, reason}

      {name, task}, {:ok, acc} ->
        case Task.yield(task, :infinity) do
          {:ok, {:ok, result}} -> {:ok, Map.put(acc, name, result)}
          {:ok, {:error, reason}} -> {:error, reason}
          {:exit, reason} -> {:error, reason}
        end
    end)
  end
end
