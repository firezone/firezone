defmodule Domain.Accounts.Config do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :search_domain, :string

    embeds_many :clients_upstream_dns, ClientsUpstreamDNS,
      primary_key: false,
      on_replace: :delete do
      field :protocol, Ecto.Enum, values: [:ip_port, :dns_over_tls, :dns_over_http]
      field :address, :string
    end

    embeds_one :notifications, Notifications,
      primary_key: false,
      on_replace: :update do
      embeds_one :outdated_gateway, Domain.Accounts.Config.Notifications.Email,
        on_replace: :update

      embeds_one :idp_sync_error, Domain.Accounts.Config.Notifications.Email, on_replace: :update
    end
  end

  def supported_dns_protocols, do: ~w[ip_port]a

  @doc """
  Returns a default config with defaults set
  """
  def default_config do
    %__MODULE__{
      notifications: %__MODULE__.Notifications{
        outdated_gateway: %Domain.Accounts.Config.Notifications.Email{enabled: true}
      }
    }
  end

  @doc """
  Ensures a config has proper defaults
  """
  def ensure_defaults(%__MODULE__{} = config) do
    notifications = config.notifications || %__MODULE__.Notifications{}

    outdated_gateway =
      notifications.outdated_gateway || %Domain.Accounts.Config.Notifications.Email{enabled: true}

    outdated_gateway =
      case outdated_gateway.enabled do
        nil -> %{outdated_gateway | enabled: true}
        _ -> outdated_gateway
      end

    notifications = %{notifications | outdated_gateway: outdated_gateway}

    %{config | notifications: notifications}
  end

  def ensure_defaults(nil), do: default_config()
end
