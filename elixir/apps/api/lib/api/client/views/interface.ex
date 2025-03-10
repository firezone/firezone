defmodule API.Client.Views.Interface do
  alias Domain.{Accounts, Clients}

  def render(%Clients.Client{} = client) do
    upstream_dns =
      client.account.config
      |> Map.get(:clients_upstream_dns, [])
      |> Enum.map(fn dns_config ->
        address = Accounts.Config.Changeset.normalize_dns_address(dns_config)
        Map.from_struct(%{dns_config | address: address})
      end)

    %{
      search_domain: client.account.config.search_domain,
      upstream_dns: upstream_dns,
      ipv4: client.ipv4,
      ipv6: client.ipv6
    }
  end
end
