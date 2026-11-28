defmodule PortalAPI.Client.Views.Interface do
  alias Portal.Device

  @doh_providers %{
    google: [%{url: "https://dns.google/dns-query"}],
    quad9: [%{url: "https://dns.quad9.net/dns-query"}],
    cloudflare: [%{url: "https://cloudflare-dns.com/dns-query"}],
    opendns: [%{url: "https://doh.opendns.com/dns-query"}]
  }

  def render(%Device{} = client, protocol_version) do
    dns_config = Map.get(client.account.config, :clients_upstream_dns)

    {upstream_do53, upstream_doh, upstream_dns} =
      case dns_config do
        %{type: :custom, addresses: addresses} when is_list(addresses) and addresses != [] ->
          do53 = Enum.map(addresses, fn %{address: address} -> %{ip: address} end)
          # Legacy field - append normalized port for backwards compatibility
          legacy_dns = Enum.map(addresses, &format_legacy_dns_address/1)

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
      ipv4: client.ipv4,
      ipv6: client.ipv6
    }
    |> put_legacy_dns(upstream_dns, protocol_version)
  end

  defp put_legacy_dns(interface, _upstream_dns, protocol_version) when protocol_version >= 5, do: interface
  defp put_legacy_dns(interface, upstream_dns, _protocol_version), do: Map.put(interface, :upstream_dns, upstream_dns)

  defp format_legacy_dns_address(%{address: address}) do
    ip = if String.contains?(address, ":"), do: "[#{address}]", else: address
    %{protocol: :ip_port, address: "#{ip}:53"}
  end
end
