defmodule PortalAPI.OktaDirectoryJSON do
  use PortalAPI.JSON,
    struct: Portal.Okta.Directory,
    schema: PortalAPI.Schemas.OktaDirectory.Schema,
    internal: [:error_email_count, :is_verified, :private_key_jwk]

  alias Portal.Okta
  alias PortalAPI.Pagination

  def index(%{directories: directories, metadata: metadata}) do
    %{data: Enum.map(directories, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{directory: directory}) do
    %{data: data(directory)}
  end

  defp data(%Okta.Directory{} = directory), do: render_fields(directory)
end
