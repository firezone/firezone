defmodule Domain.Accounts.Config do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    embeds_many :clients_upstream_dns, ClientsUpstreamDNS, primary_key: false, on_replace: :delete do
      field :protocol, Ecto.Enum, values: [:ip_port, :dns_over_tls, :dns_over_http]
      field :address, :string
    end

    embeds_one :notifications, Notifications,
      primary_key: false,
      on_replace: :update do
      embeds_one :outdated_gateway, OutdatedGateway, primary_key: false, on_replace: :update do
        field :enabled, :boolean
        field :last_notified, :utc_datetime
      end

      embeds_one :idp_sync_error, IDPSyncError, primary_key: false, on_replace: :update do
        field :enabled, :boolean
        field :last_notified, :utc_datetime
      end
    end
  end

  def supported_dns_protocols, do: ~w[ip_port]a
end
