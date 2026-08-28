defmodule PortalAPI.GoogleDirectoryJSON do
  use PortalAPI.JSON,
    struct: Portal.Google.Directory,
    schema: PortalAPI.Schemas.GoogleDirectory.Schema,
    internal: [
      :error_email_count,
      :is_verified,
      :legacy_service_account_key,
      :sync_all_domains
    ]

  alias Portal.Google
  alias PortalAPI.Pagination

  def index(%{directories: directories, metadata: metadata}) do
    %{data: Enum.map(directories, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{directory: directory}) do
    %{data: data(directory)}
  end

  defp data(%Google.Directory{} = directory), do: render_fields(directory)
end
