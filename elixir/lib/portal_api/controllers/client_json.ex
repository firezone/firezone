defmodule PortalAPI.ClientJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Device, PortalAPI.Schemas.Client.GetSchema,
    computed: [:online, :created_at],
    # psk_base is key material and must never leave the portal.
    internal: [
      :inserted_at,
      :online?,
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
  )

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

  defp data(%Device{} = device) do
    PortalAPI.JSON.render(device, PortalAPI.Schemas.Client.GetSchema, %{
      online: device.online?,
      created_at: device.inserted_at
    })
  end
end
