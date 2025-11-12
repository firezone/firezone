defmodule API.Client.Views.Interface do
  alias Domain.Clients

  def render(%Clients.Client{} = client) do
    clients_upstream_dns = Map.get(client.account.config, :clients_upstream_dns, [])

    # TODO: DOH RESOLVERS
    # Remove this old field once clients are upgraded.
    # old field - append normalized port
    upstream_dns =
      clients_upstream_dns
      |> Enum.map(fn %{address: address} = dns_config ->
        ip = URI.parse("//" <> address).host
        Map.from_struct(%{dns_config | address: "#{ip}:53"})
      end)

    # new field - no port
    upstream_do53 =
      clients_upstream_dns
      |> Enum.map(fn %{address: address} ->
        %{ip: URI.parse("//" <> address).host}
      end)

    %{
      search_domain: client.account.config.search_domain,
      upstream_do53: upstream_do53,
      # Populate from DB once present.
      upstream_doh: [],
      ipv4: client.ipv4,
      ipv6: client.ipv6,

      # Legacy field
      upstream_dns: upstream_dns
    }
  end
end
