defmodule API.Client.Views.Interface do
  alias Domain.Client

  @doh_providers %{
    google: [%{url: "https://dns.google/dns-query"}],
    quad9: [%{url: "https://dns.quad9.net/dns-query"}],
    cloudflare: [%{url: "https://cloudflare-dns.com/dns-query"}],
    opendns: [%{url: "https://doh.opendns.com/dns-query"}]
  }

  def render(%Client{} = client) do
    dns_config = Map.get(client.account.config, :clients_upstream_dns)

    {upstream_do53, upstream_doh, upstream_dns} =
      case dns_config do
        %{type: :custom, addresses: addresses} when is_list(addresses) and addresses != [] ->
          do53 = Enum.map(addresses, fn %{address: address} -> %{ip: address} end)
          # Legacy field - append normalized port for backwards compatibility
          legacy_dns =
            Enum.map(addresses, fn %{address: address} ->
              ip = if String.contains?(address, ":"), do: "[#{address}]", else: address
              %{protocol: :ip_port, address: "#{ip}:53"}
            end)

          {do53, [], legacy_dns}

        %{type: :secure, doh_provider: provider}
        when provider in [:google, :quad9, :cloudflare, :opendns] ->
          doh = @doh_providers[provider] || []
          {[], doh, []}

        _ ->
          # :system or nil or :custom with no addresses - use system resolvers
          {[], [], []}
      end

    %{
      search_domain: client.account.config.search_domain,
      upstream_do53: upstream_do53,
      upstream_doh: upstream_doh,
      ipv4: client.ipv4_address.address,
      ipv6: client.ipv6_address.address,

      # Legacy field
      upstream_dns: upstream_dns
    }
  end
end
