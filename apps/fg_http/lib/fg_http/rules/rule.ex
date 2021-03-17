defmodule FgHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import FgHttp.Util.FgNet

  alias FgHttp.{Devices, Devices.Device}

  schema "rules" do
    field :destination, EctoNetwork.INET
    field :action, RuleActionEnum, default: "deny"

    belongs_to :device, Device

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :device_id,
      :action,
      :destination
    ])
    |> validate_required([:device_id, :action, :destination])
  end

  def iptables_spec(rule) do
    device = Devices.get_device!(rule.device_id)

    source =
      case ip_type(rule.destination) do
        "IPv4" -> device.interface_address4
        "IPv6" -> device.interface_address6
        _ -> nil
      end

    {source, rule.destination, rule.action}
  end
end
