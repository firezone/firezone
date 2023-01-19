defmodule FzHttp.Gateways do
  @moduledoc """
  The Gateways context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{Gateways.Gateway, Repo, Devices, AllowRules}
  alias FzCommon.FzNet

  @default_action :deny
  @default_name "default"

  def find_or_create_default_gateway(attrs \\ %{}) do
    if count() > 0 do
      {:ok, get_gateway!()}
    else
      create_default_gateway(attrs)
    end
  end

  def create_default_gateway(attrs \\ %{}) do
    %{
      name: @default_name,
      ipv4_masquerade: Application.get_env(:fz_http, :wireguard_ipv4_masquerade),
      ipv6_masquerade: Application.get_env(:fz_http, :wireguard_ipv6_masquerade),
      ipv4_address: Application.get_env(:fz_http, :wireguard_ipv4_address),
      ipv6_address: Application.get_env(:fz_http, :wireguard_ipv6_address),
      wireguard_mtu: Application.get_env(:fz_http, :wireguard_mtu)
    }
    |> Map.merge(attrs)
    |> create_gateway()
  end

  def create_gateway(attrs \\ %{}) do
    %Gateway{}
    |> Gateway.changeset(attrs)
    |> Repo.insert()
  end

  def update_gateway(%Gateway{} = gateway, attrs) do
    gateway
    |> Gateway.changeset(attrs)
    |> Repo.update()
  end

  def delete_gateway(%Gateway{} = gateway) do
    gateway
    |> Repo.delete()
  end

  def get_gateway!, do: get_gateway!(name: @default_name)
  def get_gateway!(id: id), do: Repo.get!(Gateway, id)
  def get_gateway!(name: name), do: Repo.get_by!(Gateway, name: name)

  def gateway_config(gateway) do
    network_v4 = FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv4_network)
    network_v6 = FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv6_network)

    interface = %{
      address: [
        "#{FzNet.inet_to_ip_with_mask(gateway.ipv4_address, network_v4)}",
        "#{FzNet.inet_to_ip_with_mask(gateway.ipv6_address, network_v6)}"
      ],
      mtu: gateway.mtu,
      ipv4_masquerade: gateway.ipv4_masquerade,
      ipv6_masquerade: gateway.ipv6_masquerade,
      listen_port: FzHttp.Config.fetch_env!(:fz_http, :default_wireguard_port)
    }

    %{
      default_action: @default_action,
      rules: AllowRules.list_allow_rules(gateway) |> Enum.map(&AllowRules.as_setting/1),
      interface: interface,
      peers: Devices.as_settings() |> MapSet.to_list()
    }
  end

  def list_gateways, do: Repo.all(Gateway)

  def count, do: Repo.aggregate(Gateway, :count, :id)
end
