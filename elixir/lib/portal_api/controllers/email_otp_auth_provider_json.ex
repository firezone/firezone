defmodule PortalAPI.EmailOTPAuthProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.EmailOTP.AuthProvider, PortalAPI.Schemas.EmailOTPAuthProvider.Schema
  )

  alias Portal.EmailOTP
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%EmailOTP.AuthProvider{} = provider), do: PortalAPI.JSON.render(provider, PortalAPI.Schemas.EmailOTPAuthProvider.Schema)
end
