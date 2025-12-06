defmodule Domain.Accounts.Config do
  use Ecto.Schema
  import Ecto.Changeset

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

  @doc """
  Changeset function for embedded Config
  """
  def changeset(config \\ %__MODULE__{}, attrs) do
    config
    |> cast(attrs, [:search_domain])
    |> cast_embed(:clients_upstream_dns, with: &clients_upstream_dns_changeset/2)
    |> cast_embed(:notifications, with: &notifications_changeset/2)
  end

  defp clients_upstream_dns_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:type, :doh_provider])
    |> cast_embed(:addresses, with: &address_changeset/2)
  end

  defp address_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:address])
  end

  defp notifications_changeset(schema, attrs) do
    schema
    |> cast(attrs, [])
    |> cast_embed(:outdated_gateway, with: &email_changeset/2)
  end

  defp email_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled])
  end
end
