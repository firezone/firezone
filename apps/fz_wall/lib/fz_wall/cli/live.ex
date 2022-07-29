defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the nftables CLI.

  Rules operate on the nftables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from Firezone device IPs.
  """

  import FzWall.CLI.Helpers.Sets
  import FzWall.CLI.Helpers.Nft
  import FzCommon.FzNet, only: [ip_type: 1]
  require Logger

  @doc """
  Setup
  """
  def setup_firewall do
    teardown_table()
    setup_table()
    setup_chains()
    setup_rules(nil)
  end

  @doc """
  Adds user sets and rules.
  """
  def add_user(user_id) do
    add_user_set(user_id)
    add_chain(get_user_chain(user_id))
    set_jump_rule(user_id)
    setup_rules(user_id)
  end

  defp add_user_set(user_id) do
    list_dev_sets(user_id)
    |> Enum.map(fn set_spec -> add_dev_set(set_spec.name, set_spec.ip_type) end)
  end

  defp delete_user_set(user_id) do
    list_dev_sets(user_id)
    |> Enum.map(fn set_spec -> delete_set(set_spec.name) end)
  end

  @doc """
  Remove user sets and rules.
  """
  def delete_user(user_id) do
    delete_jump_rules(user_id)
    delete_user_set(user_id)
    delete_chain(get_user_chain(user_id))
    delete_filter_sets(user_id)
  end

  @doc """
  Adds general sets and rules.
  """
  def setup_rules(user_id) do
    add_filter_sets(user_id)
    add_filter_rules(user_id)
  end

  def set_jump_rule(user_id) do
    list_dev_sets(user_id)
    |> Enum.each(fn set_spec ->
      insert_dev_rule(set_spec.ip_type, set_spec.name, get_user_chain(user_id))
    end)
  end

  @doc """
  Adds device ip to the user's sets.
  """
  def add_device(device) do
    list_dev_sets(device.user_id)
    |> Enum.each(fn set_spec -> add_elem(set_spec.name, device[set_spec.ip_type]) end)
  end

  @doc """
  Adds rule ip to its corresponding sets.
  """
  def add_rule(rule) do
    ip_type = proto(rule.destination)
    port_type = rule.port_type
    layer4 = port_type != nil

    add_elem(
      get_filter_set_name(rule.user_id, ip_type, rule.action, layer4),
      rule.destination,
      port_type,
      get_port_range(rule.port_range)
    )
  end

  defp get_port_range(nil), do: nil
  defp get_port_range([nil, nil]), do: "1-65535"
  defp get_port_range([nil, stop]), do: "#{stop}"
  defp get_port_range([start, nil]), do: "#{start}"
  defp get_port_range([p, p]), do: "#{p}"
  defp get_port_range([start, stop]), do: "#{start}-#{stop}"

  @doc """
  Delete rule destination ip from its corresponding sets.
  """
  def delete_rule(rule) do
    ip_type = proto(rule.destination)
    port_type = rule.port_type
    ports = get_port_range(rule.port_range)
    layer4 = port_type != nil

    delete_elem(
      get_filter_set_name(rule.user_id, ip_type, rule.action, layer4),
      rule.destination,
      port_type,
      ports
    )
  end

  @doc """
  Eliminates device rules from its corresponding sets.
  """
  def delete_device(device) do
    get_ip_types()
    |> Enum.each(fn type -> remove_from_set(device.user_id, device[type], type) end)
  end

  defp remove_from_set(_user_id, nil, _type), do: :no_ip

  defp remove_from_set(user_id, ip, type) do
    get_device_set_name(user_id, type)
    |> delete_elem(ip)
  end

  defp add_filter_sets(user_id) do
    list_filter_sets(user_id)
    |> Enum.each(fn set_spec ->
      add_filter_set(set_spec.name, set_spec.ip_type, set_spec.layer4)
    end)
  end

  defp delete_filter_sets(user_id) do
    list_filter_sets(user_id)
    |> Enum.each(&delete_set/1)
  end

  defp add_filter_rules(user_id) do
    list_filter_sets(user_id)
    |> Enum.each(fn set_spec ->
      insert_filter_rule(
        get_user_chain(user_id),
        set_spec.ip_type,
        set_spec.name,
        set_spec.action,
        set_spec.layer4
      )
    end)
  end

  defp delete_jump_rules(user_id) do
    list_dev_sets(user_id)
    |> Enum.each(fn set_spec ->
      remove_dev_rule(set_spec.ip_type, set_spec.name, get_user_chain(user_id))
    end)
  end

  # xxx: here we could add multiple devices/rules in a single nft call
  def restore(%{users: users, devices: devices, rules: rules}) do
    Enum.each(users, &add_user/1)
    Enum.each(devices, &add_device/1)
    Enum.each(rules, &add_rule/1)
  end

  defp proto(ip) do
    case ip_type("#{ip}") do
      "IPv4" -> :ip
      "IPv6" -> :ip6
      "unknown" -> raise "Unknown protocol."
    end
  end
end
