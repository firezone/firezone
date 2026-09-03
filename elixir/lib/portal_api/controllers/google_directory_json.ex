defmodule PortalAPI.GoogleDirectoryJSON do
  alias Portal.Google
  alias PortalAPI.Pagination

  def index(%{directories: directories, metadata: metadata}) do
    %{data: Enum.map(directories, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{directory: directory}) do
    %{data: data(directory)}
  end

  defp data(%Google.Directory{} = directory) do
    %{
      id: directory.id,
      account_id: directory.account_id,
      name: directory.name,
      domain: directory.domain,
      impersonation_email: directory.impersonation_email,
      is_disabled: directory.is_disabled,
      disabled_reason: directory.disabled_reason,
      synced_at: directory.synced_at,
      error_message: directory.error_message,
      errored_at: directory.errored_at,
      group_sync_mode: directory.group_sync_mode,
      orgunit_sync_enabled: directory.orgunit_sync_enabled,
      inserted_at: directory.inserted_at,
      updated_at: directory.updated_at
    }
  end
end
