defmodule Domain.Accounts.Config do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    embeds_many :clients_upstream_dns, ClientsUpstreamDNS, primary_key: false, on_replace: :delete do
      field :protocol, Ecto.Enum, values: [:ip_port, :dns_over_tls, :dns_over_http]
      field :address, :string
    end
  end

  def supported_dns_protocols, do: ~w[ip_port]a
end
