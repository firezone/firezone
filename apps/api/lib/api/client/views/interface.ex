defmodule API.Client.Views.Interface do
  alias Domain.Clients

  def render(%Clients.Client{} = client) do
    %{
      upstream_dns: Domain.Config.fetch_config!(:default_client_dns),
      ipv4: client.ipv4,
      ipv6: client.ipv6
    }
  end
end
