defmodule API.Gateway.Views.Client do
  alias Domain.Clients

  def render(%Clients.Client{} = client, preshared_key) do
    %{
      id: client.id,
      public_key: client.public_key,
      preshared_key: preshared_key,
      ipv4: client.ipv4,
      ipv6: client.ipv6,
      device_serial: client.device_serial,
      firebase_installation_id: client.firebase_installation_id,
      identifier_for_vendor: client.identifier_for_vendor,
      device_uuid: client.device_uuid,
      device_user_agent: client.last_seen_user_agent
    }
  end

  # DEPRECATED IN 1.4
  def render(%Clients.Client{} = client, client_payload, preshared_key) do
    %{
      id: client.id,
      payload: client_payload,
      peer: %{
        persistent_keepalive: 25,
        public_key: client.public_key,
        preshared_key: preshared_key,
        ipv4: client.ipv4,
        ipv6: client.ipv6
      }
    }
  end
end
