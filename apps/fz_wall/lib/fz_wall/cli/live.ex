defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the nftables CLI.

  Rules operate on the nftables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from Firezone device IPs.
  """
  import FzWall.CLI.Helpers.Sets
  import FzWall.CLI.Helpers.Nft

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
  Adds device ip(s) to the user's sets, omitting missing IPs.
  """
  def add_device(device) do
    list_dev_sets(device.user_id)
    |> Enum.filter(fn set_spec ->
      # Only call add_elem/2 for IPs that are present
      device[set_spec.ip_type]
    end)
    |> Enum.each(fn set_spec ->
      add_elem(set_spec.name, device[set_spec.ip_type])
    end)
  end

  @doc """
  Adds rule ip to its corresponding sets.
  """
  def add_rule(rule) do
    modify_elem(&add_elem/4, rule)
  end

  @doc """
  Delete rule destination ip from its corresponding sets.
  """
  def delete_rule(rule) do
    modify_elem(&delete_elem/4, rule)
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
    |> Enum.each(fn set_spec -> delete_set(set_spec.name) end)
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
    case FzHttp.Types.IP.cast(ip) do
      {:ok, %{address: address}} when tuple_size(address) == 4 -> :ip
      {:ok, %{address: address}} when tuple_size(address) == 6 -> :ip6
    end
  end

  defp modify_elem(action, rule) do
    ip_type = proto(rule.destination)
    port_type = rule.port_type
    layer4 = port_type != nil

    action.(
      get_filter_set_name(rule.user_id, ip_type, rule.action, layer4),
      rule.destination,
      port_type,
      rule.port_range
    )
  end
end
