defmodule PortalAPI.OktaDirectoryJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Okta.Directory, PortalAPI.Schemas.OktaDirectory.Schema,
    internal: [:error_email_count, :is_verified, :private_key_jwk]
  )

  alias Portal.Okta
  alias PortalAPI.Pagination

  def index(%{directories: directories, metadata: metadata}) do
    %{data: Enum.map(directories, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{directory: directory}) do
    %{data: data(directory)}
  end

  defp data(%Okta.Directory{} = directory), do: PortalAPI.JSON.render(directory, PortalAPI.Schemas.OktaDirectory.Schema)
end
