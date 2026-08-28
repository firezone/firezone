defmodule PortalAPI.ClientJSON do
  use PortalAPI.JSON,
    struct: Portal.Device,
    schema: PortalAPI.Schemas.Client.GetSchema,
    aliases: [online: :online?, created_at: :inserted_at],
    # psk_base is key material and must never leave the portal.
    internal: [
      :account_id,
      :attested?,
      :client_token_id,
      :firezone_id_merged?,
      :gateway_token_id,
      :gateway_token_rotated_at,
      :last_attested_cert_issuer,
      :psk_base,
      :site_id,
      :type
    ]

  alias PortalAPI.Pagination
  alias Portal.Device

  @doc """
  Renders a list of Clients.
  """
  def index(%{clients: clients, metadata: metadata}) do
    %{
      data: Enum.map(clients, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Client
  """
  def show(%{client: client}) do
    %{data: data(client)}
  end

  defp data(%Device{} = device), do: render_fields(device)
end
