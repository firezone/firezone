defmodule API.Gateway.Views.Client do
  alias Domain.Clients

  def render(%Clients.Client{} = client, client_rtc_session_description, preshared_key) do
    %{
      id: client.id,
      rtc_session_description: client_rtc_session_description,
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
