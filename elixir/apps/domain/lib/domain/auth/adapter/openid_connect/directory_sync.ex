defmodule Domain.Auth.Adapter.OpenIDConnect.DirectorySync do
  alias Domain.Repo
  alias Domain.Jobs.Executors.Concurrent
  alias Domain.{Auth, Actors}
  require Logger
  require OpenTelemetry.Tracer

  # The Finch will timeout requests after 30 seconds,
  # but there are a lot of requests that need to be made
  # so we don't want to limit the timeout here
  @async_data_fetch_timeout :timer.minutes(30)

  # This timeout is used to limit the time spent on a single provider
  # inserting the records into the database
  @database_operations_timeout :timer.minutes(30)

  @provider_sync_timeout @async_data_fetch_timeout + @database_operations_timeout

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
  @callback gather_provider_data(%Auth.Provider{}, task_supervisor_pid :: pid()) ::
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

  def sync_providers(module, adapter, supervisor_pid) do
    start_time = System.monotonic_time(:millisecond)

    Domain.Repo.transaction(
      fn ->
        metadata = Logger.metadata()
        pdict = Process.get()
        opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()
        opentelemetry_ctx = OpenTelemetry.Ctx.get_current()

        all_providers = Domain.Auth.all_providers_pending_sync_by_adapter!(adapter)
        providers = Concurrent.reject_locked("auth_providers", all_providers)
        providers = Domain.Repo.preload(providers, :account)
        Logger.info("Syncing #{length(providers)}/#{length(all_providers)} #{adapter} providers")

        Task.Supervisor.async_stream_nolink(
          supervisor_pid,
          providers,
          fn provider ->
            OpenTelemetry.Ctx.attach(opentelemetry_ctx)
            OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

            OpenTelemetry.Tracer.with_span "sync_provider",
              attributes: %{
                account_id: provider.account_id,
                account_slug: provider.account.slug,
                provider_id: provider.id,
                provider_adapter: provider.adapter
              } do
              :ok = maybe_reuse_connection(pdict)
              Logger.metadata(metadata)

              Logger.metadata(
                account_id: provider.account_id,
                account_slug: provider.account.slug,
                provider_id: provider.id,
                provider_adapter: provider.adapter
              )

              sync_provider(module, provider)
            end
          end,
          timeout: @provider_sync_timeout,
          max_concurrency: 3
        )
        |> Enum.to_list()
        |> Enum.map(fn
          {:ok, _result} ->
            :ok

          {:exit, _reason} = reason ->
            Logger.error("Error syncing provider", crash_reason: reason)
        end)
      end,
      # sync can take a long time so we will manage timeouts for each provider separately
      timeout: :infinity
    )

    finish_time = System.monotonic_time(:millisecond)
    Logger.info("Finished syncing in #{time_taken(start_time, finish_time)}")
  end

  defp sync_provider(module, provider) do
    start_time = System.monotonic_time(:millisecond)
    Logger.debug("Syncing provider")

    if Domain.Accounts.idp_sync_enabled?(provider.account) do
      {:ok, pid} = Task.Supervisor.start_link()

      with {:ok, data, data_fetch_time_taken} <- fetch_provider_data(module, provider, pid),
           {:ok, db_operations_time_taken} <- apply_provider_updates(provider, data) do
        finish_time = System.monotonic_time(:millisecond)

        :telemetry.execute(
          [:domain, :directory_sync],
          %{
            data_fetch_total_time: data_fetch_time_taken,
            db_operations_total_time: db_operations_time_taken,
            total_time: finish_time - start_time
          },
          %{
            account_id: provider.account_id,
            provider_id: provider.id,
            provider_adapter: provider.adapter
          }
        )

        Logger.debug("Finished syncing provider in #{time_taken(start_time, finish_time)}")
      else
        _other ->
          finish_time = System.monotonic_time(:millisecond)
          Logger.debug("Failed to sync provider in #{time_taken(start_time, finish_time)}")

          :error
      end
    else
      message = "IdP sync is not enabled in your subscription plan"

      Auth.Provider.Changeset.sync_failed(provider, message)
      |> Domain.Repo.update!()

      :error
    end
  end

  defp fetch_provider_data(module, provider, task_supervisor_pid) do
    OpenTelemetry.Tracer.with_span "sync_provider.fetch_data" do
      start_time = System.monotonic_time(:millisecond)

      with {:ok, data} <- module.gather_provider_data(provider, task_supervisor_pid) do
        finish_time = System.monotonic_time(:millisecond)
        time_taken = time_taken(start_time, finish_time)

        Logger.debug(
          "Finished fetching data for provider in #{time_taken}",
          account_id: provider.account_id,
          provider_id: provider.id,
          provider_adapter: provider.adapter,
          time_taken: time_taken
        )

        {:ok, data, finish_time - start_time}
      else
        {:error, {:unauthorized, user_message}} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(user_message))

          Auth.Provider.Changeset.sync_requires_manual_intervention(provider, user_message)
          |> Domain.Repo.update!()
          |> send_sync_error_email()

          :error

        {:error, nil, log_message} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(log_message))

          log_sync_error(provider, log_message)

          :error

        {:error, user_message, log_message} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(log_message))

          Auth.Provider.Changeset.sync_failed(provider, user_message)
          |> Domain.Repo.update!()
          |> send_rate_limited_sync_error_email()
          |> log_sync_error(log_message)

          :error
      end
    end
  end

  defp apply_provider_updates(
         provider,
         {identities_attrs, actor_groups_attrs, membership_tuples}
       ) do
    OpenTelemetry.Tracer.with_span "sync_provider.insert_data" do
      Repo.checkout(
        fn ->
          start_time = System.monotonic_time(:millisecond)

          # Sync groups first because some might be excluded. If they are,
          # we don't want to insert memberships or identities for them, and instead
          # we want to delete the existing memberships and identities.
          with {:ok, groups_effects} <- Actors.sync_provider_groups(provider, actor_groups_attrs),
               {:ok, identities_effects} <-
                 Auth.sync_provider_identities(provider, identities_attrs),
               {:ok, memberships_effects} <-
                 Actors.sync_provider_memberships(
                   identities_effects.actor_ids_by_provider_identifier,
                   groups_effects.group_ids_by_provider_identifier,
                   provider,
                   membership_tuples
                 ),
               # TODO: Return effects here for logging
               :ok <- Actors.delete_excluded_associations(provider) do
            Auth.Provider.Changeset.sync_finished(provider)
            |> Repo.update!()

            finish_time = System.monotonic_time(:millisecond)

            log_sync_result(
              start_time,
              finish_time,
              identities_effects,
              groups_effects,
              memberships_effects
            )

            {:ok, finish_time - start_time}
          else
            {:error, reason} ->
              OpenTelemetry.Tracer.set_status(:error, inspect(reason))
              log_sync_error(provider, "Repo error: " <> inspect(reason))
              :error
          end
        end,
        timeout: @database_operations_timeout
      )
    end
  end

  defp log_sync_result(
         start_time,
         finish_time,
         %{
           plan: {identities_insert_ids, identities_update_ids, identities_delete_ids},
           inserted: identities_inserted,
           updated: identities_updated,
           deleted: identities_deleted
         },
         %{
           plan: {groups_upsert_ids, groups_delete_ids},
           upserted: groups_upserted,
           deleted: groups_deleted
         },
         %{
           plan: {memberships_insert_tuples, memberships_delete_tuples},
           inserted: memberships_inserted,
           deleted_stats: {deleted_memberships_count, _}
         }
       ) do
    time_taken = time_taken(start_time, finish_time)

    Logger.debug("Finished syncing provider in #{time_taken}",
      time_taken: time_taken,
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

  defp time_taken(start_time, finish_time) do
    ~T[00:00:00]
    |> Time.add(finish_time - start_time, :millisecond)
    |> to_string()
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

          OpenTelemetry.Tracer.with_span "sync_provider.fetch_data.#{name}" do
            callback.()
          end
        end)

      {name, task}
    end)
    |> Enum.reduce({:ok, %{}}, fn
      {_name, task}, {:error, reason} ->
        Task.Supervisor.terminate_child(supervisor, task.pid)
        {:error, reason}

      {name, task}, {:ok, acc} ->
        case Task.yield(task, @async_data_fetch_timeout) || Task.shutdown(task) do
          {:ok, {:ok, result}} -> {:ok, Map.put(acc, name, result)}
          {:ok, {:error, reason}} -> {:error, reason}
          {:exit, reason} -> {:error, reason}
        end
    end)
  end

  defp send_rate_limited_sync_error_email(provider) do
    if notification_criteria_met?(provider) do
      send_sync_error_email(provider)
    else
      Logger.debug("Sync error email already sent today")
      provider
    end
  end

  defp send_sync_error_email(provider) do
    provider = Repo.preload(provider, :account)

    Domain.Actors.all_admins_for_account!(provider.account, preload: :identities)
    |> Enum.flat_map(fn actor ->
      Enum.map(actor.identities, &Domain.Auth.get_identity_email(&1))
    end)
    |> Enum.uniq()
    |> Enum.each(fn email ->
      Domain.Mailer.SyncEmail.sync_error_email(provider, email)
      |> Domain.Mailer.deliver()
    end)

    Auth.Provider.Changeset.sync_error_emailed(provider)
    |> Domain.Repo.update!()
  end

  defp notification_criteria_met?(provider) do
    provider.last_syncs_failed >= 10 and !sync_error_email_sent_today?(provider)
  end

  defp sync_error_email_sent_today?(provider) do
    if last_email_time = provider.sync_error_emailed_at do
      DateTime.diff(DateTime.utc_now(), last_email_time, :hour) < 24
    else
      false
    end
  end

  if Mix.env() == :test do
    # We need this function to reuse the connection that was checked out in a parent process.
    #
    # `Ecto.SQL.Sandbox.allow/3` will not work in this case because it will try to checkout the same connection
    # that is held by the parent process by `Repo.checkout/2` which will lead to a timeout, so we need to hack
    # and reuse it manually.
    def maybe_reuse_connection(pdict) do
      pdict
      |> Enum.filter(fn
        {{Ecto.Adapters.SQL, _pid}, _} -> true
        _ -> false
      end)
      |> Enum.each(fn {key, value} ->
        Process.put(key, value)
      end)
    end
  else
    def maybe_reuse_connection(_pdict) do
      :ok
    end
  end
end
