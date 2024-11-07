defmodule API.Gateway.Views.Client do
  alias Domain.Clients

  def render(%Clients.Client{} = client, preshared_key) do
    %{
      id: client.id,
      public_key: client.public_key,
      preshared_key: preshared_key,
      ipv4: client.ipv4,
      ipv6: client.ipv6
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
