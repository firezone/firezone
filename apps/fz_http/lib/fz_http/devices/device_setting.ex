defmodule FzHttp.Devices.DeviceSetting do
  @moduledoc """
  Device setting parsed from either a Device struct or map.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import FzHttp.Devices, only: [decode: 1]

  @primary_key false
  embedded_schema do
    field :ip, :string
    field :ip6, :string
    field :user_id, :integer
  end

  def parse(device) when is_struct(device) do
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
    |> apply_changes()
  end
end
