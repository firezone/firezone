defmodule API.Client.Views.Interface do
  alias Domain.Clients

  def render(%Clients.Client{} = client) do
    upstream_do53_entries = Map.get(client.account.config, :upstream_do53, [])

    # TODO: DOH RESOLVERS
    # Remove this old field once clients are upgraded.
    # Legacy field - append normalized port for backwards compatibility
    upstream_dns =
      upstream_do53_entries
      |> Enum.map(fn %{address: address} ->
        %{protocol: "ip_port", address: "#{address}:53"}
      end)

    # New field - just IPs
    upstream_do53 =
      upstream_do53_entries
      |> Enum.map(fn %{address: address} ->
        %{ip: address}
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
