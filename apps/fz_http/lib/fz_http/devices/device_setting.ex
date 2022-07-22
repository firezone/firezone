defmodule FzHttp.Devices.DeviceSetting do
  @moduledoc """
  Device setting parsed from either a Device or Map.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import FzHttp.Devices, only: [decode: 1]

  alias FzHttp.Devices.Device

  @primary_key false
  embedded_schema do
    field :ip, :string
    field :ip6, :string
    field :user_id, :integer
  end

  def parse(%Device{} = device) do
    %__MODULE__{
      ip: decode(device.ipv4),
      ip6: decode(device.ipv6),
      user_id: device.user_id
    }
  end

  def parse(device) when is_map(device) do
    device =
      device
      |> Map.put(:ip, Map.get(device, :ipv4))
      |> Map.put(:ip6, Map.get(device, :ipv6))

    %__MODULE__{}
    |> cast(device, [:ip, :ip6, :user_id])
    |> validate_required(:user_id)
    |> validate_ip_required()
    |> validate_ip6_required()
    |> apply_changes()
  end

  defp validate_ip_required(changeset) do
    if Application.fetch_env!(:fz_http, :wireguard_ipv4_enabled) do
      validate_required(changeset, :ip)
    else
      changeset
    end
  end

  defp validate_ip6_required(changeset) do
    if Application.fetch_env!(:fz_http, :wireguard_ipv6_enabled) do
      validate_required(changeset, :ip6)
    else
      changeset
    end
  end
end
