defmodule Domain.Accounts.Config do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :search_domain, :string

    embeds_one :clients_upstream_dns, ClientsUpstreamDns,
      primary_key: false,
      on_replace: :update do
      field :type, Ecto.Enum, values: [:system, :secure, :custom], default: :system

      field :doh_provider, Ecto.Enum,
        values: [:google, :opendns, :cloudflare, :quad9],
        default: :google

      embeds_many :addresses, Address,
        primary_key: false,
        on_replace: :delete do
        field :address, :string
      end
    end

    embeds_one :notifications, Notifications,
      primary_key: false,
      on_replace: :update do
      embeds_one :outdated_gateway, Domain.Accounts.Config.Notifications.Email,
        on_replace: :update

      embeds_one :idp_sync_error, Domain.Accounts.Config.Notifications.Email, on_replace: :update
    end
  end

  @doc """
  Returns a default config with defaults set
  """
  def default_config do
    %__MODULE__{
      clients_upstream_dns: %__MODULE__.ClientsUpstreamDns{
        type: :system
      },
      notifications: %__MODULE__.Notifications{
        outdated_gateway: %Domain.Accounts.Config.Notifications.Email{enabled: true}
      }
    }
  end

  @doc """
  Ensures a config has proper defaults
  """
  def ensure_defaults(%__MODULE__{} = config) do
    # Ensure notifications defaults
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
