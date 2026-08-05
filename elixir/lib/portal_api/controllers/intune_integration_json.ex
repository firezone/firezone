defmodule PortalAPI.IntuneIntegrationJSON do
  alias Portal.Intune

  def index(%{integrations: integrations}), do: %{data: Enum.map(integrations, &data/1)}
  def show(%{integration: integration}), do: %{data: data(integration)}

  defp data(%Intune.Integration{} = integration) do
    %{
      id: integration.id,
      account_id: integration.account_id,
      type: "intune",
      name: integration.name,
      tenant_id: integration.tenant_id,
      is_verified: integration.is_verified,
      is_disabled: integration.is_disabled,
      disabled_reason: integration.disabled_reason,
      synced_at: integration.synced_at,
      errored_at: integration.errored_at,
      error_message: integration.error_message,
      inserted_at: integration.inserted_at,
      updated_at: integration.updated_at
    }
  end
end
