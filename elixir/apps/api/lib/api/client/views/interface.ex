defmodule API.Client.Views.Interface do
  alias Domain.{Accounts, Clients}

  def render(%Clients.Client{} = client) do
    # Legacy field
    upstream_dns =
      client.account.config
      |> Map.get(:clients_upstream_dns, [])
      |> Enum.map(fn dns_config ->
        address = Accounts.Config.Changeset.normalize_dns_address(dns_config)
        Map.from_struct(%{dns_config | address: address})
      end)

    upstream_do53 =
      for %{protocol: :ip_port, address: address} <-
            Map.get(client.account.config, :clients_upstream_dns, []),
          {:ok, ip_port} <- [Domain.Types.IPPort.cast(address)] do
        %{ip: Domain.Types.IPPort.to_string(%{ip_port | port: nil})}
      end

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
