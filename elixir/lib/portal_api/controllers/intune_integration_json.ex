defmodule PortalAPI.IntuneIntegrationJSON do
  alias Portal.Intune

  def show(%{integration: integration}), do: %{data: data(integration)}

  # error_email_count is notification bookkeeping, not part of the public shape.
  @fields Intune.Integration.__schema__(:fields) -- [:error_email_count]

  defp data(%Intune.Integration{} = integration),
    do: integration |> Map.take(@fields) |> Map.put(:type, "intune")
end
