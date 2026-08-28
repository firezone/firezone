defmodule PortalAPI.EmailOTPAuthProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.EmailOTP.AuthProvider,
    schema: PortalAPI.Schemas.EmailOTPAuthProvider.Schema

  alias Portal.EmailOTP
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%EmailOTP.AuthProvider{} = provider), do: render_fields(provider)
end
