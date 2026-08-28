defmodule PortalAPI.X509AuthProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.X509.AuthProvider,
    schema: PortalAPI.Schemas.X509AuthProvider.Schema

  alias Portal.X509

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%X509.AuthProvider{} = provider), do: render_fields(provider)
end
