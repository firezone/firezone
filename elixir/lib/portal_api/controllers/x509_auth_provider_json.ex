defmodule PortalAPI.X509AuthProviderJSON do
  alias Portal.X509

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%X509.AuthProvider{} = provider) do
    %{
      id: provider.id,
      account_id: provider.account_id,
      name: provider.name,
      context: provider.context,
      is_disabled: provider.is_disabled,
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }
  end
end
