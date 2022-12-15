defmodule FzHttp.Gateways do
  @moduledoc """
  The Gateways context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.Devices
  alias FzHttp.{Gateways.Gateway, Repo}

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

  def get_gateway!(id: id), do: Repo.get!(Gateway, id)
  def get_gateway!(name: name), do: Repo.get_by!(Gateway, name: name)

  # default_action: "deny",
  # interface: %{
  # address: ["100.64.11.22/10"],
  # mtu: 1280
  # },
  # peers: [
  # %{
  # allowed_ips: [
  # "100.64.11.22/32"
  # ],
  # public_key: "AxVaJsPC1FSrOM5RpEXg4umTKMxkHkgMy1fl7t1xyyw=",
  # preshared_key: "LZBIpoLNCkIe56cPM+5pY/hP2pu7SGARvQZEThmuPYM=",
  # user_uuid: "3118158c-29cb-47d6-adbf-5edd15f1af17"
  # }
  # ]
  # }
  def gateway_config(gateway) do
    default_action = :deny

    interface = %{
      address: ["#{gateway.ipv4_address}/32", "#{gateway.ipv6_address}/128"],
      mtu: gateway.mtu
    }

    peers = Devices.as_settings() |> MapSet.to_list()

    %{
      default_action: default_action,
      interface: interface,
      peers: peers
    }
  end

  def list_gateways, do: Repo.all(Gateway)
end
