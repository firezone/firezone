defmodule Domain.Entra.Jobs.Sync do
  # Retries are handled by the scheduler
  use Oban.Worker, queue: :entra_sync, max_attempts: 1
  alias Domain.Entra
  require Logger

  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    Logger.debug("Starting Entra directory sync", entra_directory_id: id)

    case Entra.fetch_directory_for_sync(id) do
      {:ok, directory} ->
        sync(directory)

      {:error, :not_found} ->
        Logger.debug("Entra directory deleted or sync disabled, skipping", entra_directory_id: id)
    end
  end

  defp sync(%Entra.Directory{} = directory) do
    Logger.debug("Syncing Entra directory",
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
      Logger.debug("Group filtering is enabled, performing optimized full sync",
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
      Logger.debug("Group filtering is disabled, performing delta syncs",
        entra_directory_id: directory.id
      )

      # TODO
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

  # Called on each batch of groups + users
  defp full_sync_callback(directory, synced_at, groups_with_users) do
    Logger.debug("Inserting groups callback called")
    Logger.debug(inspect(groups_with_users, pretty: true))
  end

  defp delete_unsynced(directory, synced_at) do
    Logger.debug("Deleting unsynced groups and users", entra_directory_id: directory.id)
  end
end
