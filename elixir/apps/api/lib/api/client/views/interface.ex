defmodule API.Client.Views.Interface do
  alias Domain.Clients
  alias Domain.Config.Configuration.ClientsUpstreamDNS

  def render(%Clients.Client{} = client) do
    upstream_dns =
      Clients.fetch_client_config!(client)
      |> Map.fetch!(:clients_upstream_dns)
      |> Enum.map(fn dns_config ->
        addr = ClientsUpstreamDNS.normalize_dns_address(dns_config)
        Map.from_struct(%{dns_config | address: addr})
      end)

    %{
      upstream_dns: upstream_dns,
      ipv4: client.ipv4,
      ipv6: client.ipv6
    }
  end
end
