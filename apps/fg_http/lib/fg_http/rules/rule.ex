defmodule FgHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Devices, Devices.Device}

  schema "rules" do
    field :destination, EctoNetwork.INET
    field :action, RuleActionEnum, default: :block
    field :enabled, :boolean, default: true

    belongs_to :device, Device

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :device_id,
      :action,
      :destination,
      :enabled
    ])
    |> validate_required([:device_id, :action, :destination, :enabled])
  end

  def iptables_spec(rule) do
    device = Devices.get_device!(rule.device_id)

    source =
      if ipv4?(rule) do
        device.interface_address4
      else
        device.interface_address6
      end

    {source, rule.destination, rule.action}
  end

  defp ipv4?(rule) do
    case parse_ipv4(rule) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp parse_ipv4(rule) do
    rule.destination
    |> String.to_charlist()
    |> :inet.parse_ipv4_address()
  end
end
