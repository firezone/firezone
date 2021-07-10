defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  alias EctoNetwork.INET
  alias FzCommon.FzNet

  alias FzHttp.{Devices.Device, Repo, Rules.Rule}

  def get_rule!(id), do: Repo.get!(Rule, id)

  def new_rule(attrs \\ %{}) do
    %Rule{}
    |> Rule.changeset(attrs)
  end

  def create_rule(attrs \\ %{}) do
    attrs
    |> new_rule()
    |> Repo.insert()
  end

  def delete_rule(%Rule{} = rule) do
    Repo.delete(rule)
  end

  def to_iptables do
    Enum.map(iptables_query(), fn {int4, int6, dest, act} ->
      {
        decode(int4),
        decode(int6),
        decode(dest),
        act
      }
    end)
  end

  def iptables_spec(rule) do
    device = Repo.preload(rule, :device).device
    dest = decode(rule.destination)

    # I pass INET.decode as a function to FzNet so that I don't need
    # to include ecto_network as a dependency in FzCommon.
    source =
      case FzNet.ip_type(dest) do
        "IPv6" -> device.interface_address6
        "IPv4" -> device.interface_address4
        _ -> nil
      end

    {decode(source), dest, rule.action}
  end

  def allowlist(device) when is_map(device), do: allowlist(device.id)

  def allowlist(device_id) when is_binary(device_id) or is_number(device_id) do
    Repo.all(
      from r in Rule,
        where: r.device_id == ^device_id and r.action == :allow
    )
  end

  def denylist(device) when is_map(device), do: denylist(device.id)

  def denylist(device_id) when is_binary(device_id) or is_number(device_id) do
    Repo.all(
      from r in Rule,
        where: r.device_id == ^device_id and r.action == :deny
    )
  end

  defp iptables_query do
    query =
      from d in Device,
        join: r in Rule,
        on: r.device_id == d.id,
        order_by: r.action,
        select: {
          # Need to select both ipv4 and ipv6 since we don't know which the
          # corresponding rule is.
          d.interface_address4,
          d.interface_address6,
          r.destination,
          r.action
        }

    Repo.all(query)
  end

  defp decode(nil), do: nil
  defp decode(inet), do: INET.decode(inet)
end
