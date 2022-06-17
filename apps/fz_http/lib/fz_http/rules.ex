defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  import FzCommon.FzNet
  alias EctoNetwork.INET

  alias FzHttp.{Repo, Rules.Rule, Telemetry}

  def list_rules, do: Repo.all(Rule)

  def list_rules(user_id) do
    Repo.all(
      from r in Rule,
        where: r.user_id == ^user_id
    )
  end

  def get_rule!(id), do: Repo.get!(Rule, id)

  def new_rule(attrs \\ %{}) do
    %Rule{}
    |> Rule.changeset(attrs)
  end

  def create_rule(attrs \\ %{}) do
    result =
      attrs
      |> new_rule()
      |> Repo.insert()

    case result do
      {:ok, _rule} ->
        Telemetry.add_rule()

      _ ->
        nil
    end

    result
  end

  def delete_rule(%Rule{} = rule) do
    Telemetry.delete_rule()
    Repo.delete(rule)
  end

  def allowlist do
    Repo.all(
      from r in Rule,
        where: r.action == :accept
    )
  end

  def denylist do
    Repo.all(
      from r in Rule,
        where: r.action == :drop
    )
  end

  def nftables_device_spec(device) do
    rules = FzHttp.Rules.list_rules(device.user_id)

    Enum.map(rules, fn rule ->
      {get_device_ip(device, ip_type("#{rule.destination}")), decode(rule.destination),
       rule.action}
    end)
    # XXX: This should only be needed if a destination can be ipv4/v6 while ipv4/v6
    # is disabled in firezone
    |> Enum.reject(fn {source, _, _} -> is_nil(source) end)
    |> Enum.map(fn {s, d, r} -> {decode(s), d, r} end)
  end

  def nftables_spec(rule) do
    nftables_spec(rule, rule.user_id)
  end

  defp nftables_spec(rule, nil) do
    [{decode(rule.destination), rule.action}]
  end

  defp nftables_spec(rule, user_id) do
    get_user_ips(user_id, ip_type("#{rule.destination}"))
    # XXX: This should only be needed if a destination can be ipv4/v6 while ipv4/v6
    # is disabled in firezone
    |> Enum.reject(fn ip -> is_nil(ip) end)
    |> Enum.map(fn source -> {decode(source), decode(rule.destination), rule.action} end)
  end

  defp get_device_ip(device, "IPv4"), do: device.ipv4
  defp get_device_ip(device, "IPv6"), do: device.ipv6
  defp get_device_ip(_, "unknown"), do: raise("Unknown protocol")

  defp get_user_ips(user_id, "IPv4") do
    Enum.map(FzHttp.Devices.list_devices(user_id), fn device ->
      device.ipv4
    end)
  end

  defp get_user_ips(user_id, "IPv6") do
    Enum.map(FzHttp.Devices.list_devices(user_id), fn device ->
      device.ipv6
    end)
  end

  defp get_user_ips(_, "unknown") do
    raise "Unknown protocol."
  end

  def to_nftables do
    Enum.flat_map(nftables_query(), fn rule ->
      nftables_spec(rule)
    end)
  end

  defp nftables_query do
    query =
      from r in Rule,
        order_by: r.action

    Repo.all(query)
  end

  def decode(nil), do: nil
  def decode(inet), do: INET.decode(inet)
end
