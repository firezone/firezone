defmodule Domain.Entra.Jobs.Sync do
  # Retries and uniqueness are handled by the scheduler
  use Oban.Worker,
    queue: :entra_sync,
    max_attempts: 1

  alias Domain.Entra
  require Logger

  # How many pages to fetch in each request to the Graph API
  @page_size 999

  # How many records to batch-upsert at once
  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    Logger.info("#{inspect(DateTime.utc_now(), pretty: true)} Starting Entra directory sync",
      entra_directory_id: id
    )

    case Entra.fetch_directory_for_sync(id) do
      {:ok, directory} ->
        sync(directory)

      {:error, :not_found} ->
        Logger.info("Entra directory deleted or sync disabled, skipping", entra_directory_id: id)
    end

    :ok
  end

  defp sync(%Entra.Directory{} = directory) do
    start = DateTime.utc_now()
    access_token = get_access_token!(directory)
    synced_at = DateTime.utc_now()
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

    duration = DateTime.diff(DateTime.utc_now(), start)

    # Show a human-friendly duration in hours, minutes, seconds
    Logger.info("Finished Entra directory sync in #{duration} seconds",
      entra_directory_id: directory
    )
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

  defp batch_upsert(
         directory,
         synced_at,
         %{
           groups: groups,
           identities: identities,
           memberships: memberships
         } = to_upsert
       ) do
    # TODO: batch size

    {:ok, upserted_groups} =
      Domain.Actors.batch_upsert_groups(directory.auth_provider, groups, synced_at)

    {:ok, upserted_identities} =
      Domain.Auth.batch_upsert_identities_with_actors(
        directory.auth_provider,
        identities,
        synced_at
      )

    :ok =
      Domain.Actors.batch_upsert_group_memberships(
        directory.auth_provider,
        memberships,
        upserted_groups,
        upserted_identities,
        synced_at
      )
  end

  defp delete_unsynced(directory, synced_at) do
    {:ok, count} = Domain.Actors.delete_unsynced_groups(directory.auth_provider, synced_at)
    Logger.info("Deleted #{count} unsynced groups", entra_directory_id: directory.id)

    {:ok, count} =
      Domain.Auth.delete_unsynced_identities_and_actors(directory.auth_provider, synced_at)

    Logger.info("Deleted #{count} unsynced identities and actors",
      entra_directory_id: directory.id
    )

    {:ok, count} =
      Domain.Actors.delete_unsynced_group_memberships(directory.auth_provider, synced_at)

    Logger.info("Deleted #{count} unsynced group memberships", entra_directory_id: directory.id)
  end
end
