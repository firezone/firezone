defmodule PortalAPI.EntraDirectoryJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Entra.Directory, PortalAPI.Schemas.EntraDirectory.Schema,
    internal: [:error_email_count, :is_verified]
  )

  alias Portal.Entra
  alias PortalAPI.Pagination

  def index(%{directories: directories, metadata: metadata}) do
    %{data: Enum.map(directories, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{directory: directory}) do
    %{data: data(directory)}
  end

  defp data(%Entra.Directory{} = directory), do: PortalAPI.JSON.render(directory, PortalAPI.Schemas.EntraDirectory.Schema)
end
