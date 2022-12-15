defmodule FzHttp.Configurations.Configuration do
  @moduledoc """
  App global configuration, singleton resource
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias EctoNetwork.CIDR
  alias FzHttp.Configurations.Logo
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "configurations" do
    embeds_one :logo, Logo, on_replace: :update
    field :local_auth_enabled, :boolean
    field :allow_unprivileged_device_management, :boolean
    field :allow_unprivileged_device_configuration, :boolean
    field :openid_connect_providers, :map
    field :saml_identity_providers, :map
    field :disable_vpn_on_oidc_error, :boolean
    field :default_client_allowed_ips, :string, default: "0.0.0.0/0, ::/0"
    field :default_client_dns, :string, default: "1.1.1.1, 1.0.0.1"
    field :default_client_endpoint, :string
    field :default_client_mtu, :integer, default: 1280
    field :default_client_persistent_keepalive, :integer, default: 0
    field :default_client_port, :integer, default: 51_820
    field :ipv4_enabled, :boolean, default: true
    field :ipv6_enabled, :boolean, default: true
    field :ipv4_network, CIDR, default: CIDR.cast("10.3.2.0/24") |> elem(1)
    field :ipv6_network, CIDR, default: CIDR.cast("fd00::3:2:0/120") |> elem(1)
    field :vpn_session_duration, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [
      :local_auth_enabled,
      :allow_unprivileged_device_management,
      :allow_unprivileged_device_configuration,
      :openid_connect_providers,
      :saml_identity_providers,
      :disable_vpn_on_oidc_error,
      :default_client_allowed_ips,
      :default_client_dns,
      :default_client_endpoint,
      :default_client_mtu,
      :default_client_persistent_keepalive,
      :default_client_port,
      :ipv4_enabled,
      :ipv6_enabled,
      :ipv4_network,
      :ipv6_network,
      :vpn_session_duration
    ])
    |> cast_embed(:logo)
  end
end
