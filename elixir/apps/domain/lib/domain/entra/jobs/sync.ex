defmodule Domain.Entra.Jobs.Sync do
  use Oban.Worker, queue: :entra_sync, max_attempts: 3
  alias Domain.Entra
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{id: id}}) do
    Logger.debug("Starting Entra directory sync", entra_directory_id: id)

    case Entra.fetch_directory_for_sync(id) do
      {:ok, directory} ->
        start_sync(directory)

      {:error, :not_found} ->
        Logger.debug("Entra directory deleted or sync disabled, skipping", entra_directory_id: id)
    end
  end

  defp start_sync(%Entra.Directory{} = directory) do
    Logger.debug("Syncing Entra directory",
      entra_directory_id: directory.id,
      account_id: directory.account_id,
      auth_provider_id: directory.auth_provider_id
    )
  end
end
