defmodule API.Client.Views.Interface do
  alias Domain.Clients

  def render(%Clients.Client{} = client) do
    upstream_dns =
      Clients.fetch_client_config!(client)
      |> Keyword.fetch!(:upstream_dns)

    %{
      upstream_dns: upstream_dns,
      ipv4: client.ipv4,
      ipv6: client.ipv6
    }
  end
end
