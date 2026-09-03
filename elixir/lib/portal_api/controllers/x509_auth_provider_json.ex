defmodule PortalAPI.X509AuthProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.X509.AuthProvider, PortalAPI.Schemas.X509AuthProvider.Schema
  )

  alias Portal.X509

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%X509.AuthProvider{} = provider), do: PortalAPI.JSON.render(provider, PortalAPI.Schemas.X509AuthProvider.Schema)
end
