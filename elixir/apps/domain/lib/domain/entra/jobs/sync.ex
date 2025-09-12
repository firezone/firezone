defmodule Domain.Entra.Jobs.Sync do
  # Retries are handled by the scheduler
  use Oban.Worker, queue: :entra_sync, max_attempts: 1
  alias Domain.Entra
  require Logger

  # How many pages to fetch in each request to the Graph API
  @page_size 999

  # How many records to batch-upsert at once
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
    synced_at = DateTime.utc_now()

    Logger.info("Group filtering is enabled, performing optimized full sync",
      entra_directory_id: directory.id
    )

    only_groups = Enum.map(directory.group_inclusions, & &1.external_id)

    case Entra.APIClient.fetch_all(
           access_token,
           only_groups,
           @page_size,
           fn to_upsert ->
             batch_upsert(directory, synced_at, to_upsert)
           end
         ) do
      :ok ->
        delete_unsynced(directory, synced_at)

      {:error, %Req.Response{} = response} ->
        raise Entra.SyncError, response: response, directory_id: directory.id
    end
  end

  defp get_access_token!(directory) do
    tenant_id = directory.tenant_id
    client_id = directory.client_id
    client_secret = directory.client_secret

    case Entra.APIClient.fetch_access_token(tenant_id, client_id, client_secret) do
      {:ok, access_token} ->
        access_token

      {:error, %Req.Response{} = response} ->
        raise Entra.SyncError, response: response, directory_id: directory.id
    end
  end

  defp batch_upsert(directory, synced_at, %{
         groups: groups,
         identities: identities,
         memberships: memberships
       }) do
    Logger.info(inspect(groups, pretty: true))
    Logger.info(inspect(identities, pretty: true))
    Logger.info(inspect(memberships, pretty: true))
  end

  defp delete_unsynced(directory, synced_at) do
    Logger.info("Deleting unsynced groups and users", entra_directory_id: directory.id)
  end
end
