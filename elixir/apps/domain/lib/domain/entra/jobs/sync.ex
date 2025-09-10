defmodule Domain.Entra.Jobs.Sync do
  # Retries are handled by the scheduler
  use Oban.Worker, queue: :entra_sync, max_attempts: 1
  alias Domain.Entra
  require Logger

  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    Logger.info("Starting Entra directory sync", entra_directory_id: id)

    case Entra.fetch_directory_for_sync(id) do
      {:ok, directory} ->
        sync(directory)

      {:error, :not_found} ->
        Logger.info("Entra directory deleted or sync disabled, skipping", entra_directory_id: id)
    end
  end

  defp sync(%Entra.Directory{} = directory) do
    Logger.info("Syncing Entra directory",
      entra_directory_id: directory.id,
      account_id: directory.account_id,
      auth_provider_id: directory.auth_provider_id
    )

    access_token = get_access_token!(directory)
    filtering_enabled? = Enum.any?(directory.group_inclusions)
    synced_at = DateTime.utc_now()

    # The Graph API doesn't support delta + filtering by more than 50 items, so if group filtering is enabled,
    # we perform an optimized full sync. If it's disabled we perform delta syncs.
    if filtering_enabled? do
      Logger.info("Group filtering is enabled, performing optimized full sync",
        entra_directory_id: directory.id
      )

      only_groups = Enum.map(directory.group_inclusions, & &1.external_id)

      Entra.APIClient.full_sync(
        access_token,
        only_groups,
        @batch_size,
        fn groups_with_users ->
          full_sync_callback(directory, synced_at, groups_with_users)
        end
      )

      delete_unsynced(directory, synced_at)
    else
      Logger.info("Group filtering is disabled, performing delta syncs",
        entra_directory_id: directory.id
      )

      Entra.APIClient.delta_sync_users(
        access_token,
        directory.users_delta_link,
        @batch_size,
        fn users, new_delta_link ->
          delta_sync_users_callback(directory, users, new_delta_link)
        end
      )

      Entra.APIClient.delta_sync_groups(
        access_token,
        directory.groups_delta_link,
        @batch_size,
        fn groups_with_members, new_delta_link ->
          delta_sync_groups_callback(directory, groups_with_members, new_delta_link)
        end
      )
    end
  end

  defp get_access_token!(directory) do
    tenant_id = directory.tenant_id
    client_id = directory.auth_provider.adapter_config["client_id"]
    client_secret = directory.auth_provider.adapter_config["client_secret"]

    case Entra.APIClient.fetch_access_token(tenant_id, client_id, client_secret) do
      {:ok, access_token} ->
        access_token

      {:error, %Req.Response{} = response} ->
        raise Entra.SyncError, response: response, directory_id: directory.id
    end
  end

  defp full_sync_callback(directory, synced_at, groups_with_users) do
    Logger.info("Inserting groups callback called")
    Logger.info(inspect(groups_with_users, pretty: true))
  end

  defp delete_unsynced(directory, synced_at) do
    Logger.info("Deleting unsynced groups and users", entra_directory_id: directory.id)
  end

  defp delta_sync_users_callback(directory, users, nil) do
    Logger.info("Delta sync users callback called, more remaining")
    Logger.info(inspect(users, pretty: true))
  end

  defp delta_sync_users_callback(directory, users, new_delta_link) do
    Logger.info("Delta sync users completed")
    Logger.info(inspect(users, pretty: true))
    Logger.info("New delta link: #{new_delta_link}")
  end

  defp delta_sync_groups_callback(directory, groups_with_members, nil) do
    Logger.info("Delta sync groups callback called, more remaining")
    Logger.info(inspect(groups_with_members, pretty: true))
  end

  defp delta_sync_groups_callback(directory, groups_with_members, new_delta_link) do
    Logger.info("Delta sync groups completed")
    Logger.info(inspect(groups_with_members, pretty: true))
    Logger.info("New delta link: #{new_delta_link}")
  end
end
