defmodule PortalAPI.GatewayJSON do
  use PortalAPI.JSON,
    struct: Portal.Device,
    schema: PortalAPI.Schemas.Gateway.Schema,
    aliases: [online: :online?, rotated_at: :gateway_token_rotated_at],
    # psk_base is key material and must never leave the portal.
    internal: [
      :account_id,
      :actor_id,
      :attested?,
      :client_token_id,
      :device_serial,
      :device_uuid,
      :firebase_installation_id,
      :firezone_id,
      :firezone_id_merged?,
      :hostname,
      :identifier_for_vendor,
      :inserted_at,
      :last_attested_at,
      :last_attested_cert_fingerprint,
      :last_attested_cert_issuer,
      :last_attested_cert_serial,
      :last_attested_device_serial,
      :last_attested_device_uuid,
      :last_attested_mdm_device_id,
      :psk_base,
      :site_id,
      :type,
      :updated_at,
      :verified_at
    ]

  alias PortalAPI.Pagination
  alias Portal.Device

  @doc """
  Renders a list of Gateways.
  """
  def index(%{gateways: gateways, metadata: metadata}) do
    %{
      data: Enum.map(gateways, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Gateway
  """
  def show(%{gateway: gateway}) do
    %{data: data(gateway)}
  end

  @doc """
  Renders a newly provisioned Gateway along with its one-time token secret.
  """
  def provisioned(%{gateway: gateway, encoded_token: encoded_token}) do
    %{data: Map.put(data(gateway), :token, encoded_token)}
  end

  defp data(%Device{} = device), do: render_fields(device)
end
