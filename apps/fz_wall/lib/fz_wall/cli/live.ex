defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the nftables CLI.

  Rules operate on the nftables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from Firezone device IPs.
  """

  import FzWall.CLI.Helpers.Sets
  import FzWall.CLI.Helpers.Nft
  import FzCommon.CLI
  import FzCommon.FzNet, only: [ip_type: 1]
  require Logger

  @doc """
  Setup
  """
  def setup_firewall do
    teardown_table()
    setup_table()
    setup_chains()
    setup_rules()
  end

  @doc """
  Adds user sets and rules.
  """
  def add_user(user_id) do
    add_sets(user_id)
    add_rules(user_id)
  end

  @doc """
  Remove user sets and rules.
  """
  def delete_user(user_id) do
    delete_rules(user_id)
    delete_sets(user_id)
  end

  @doc """
  Adds general sets and rules.
  """
  def setup_rules do
    add_sets(nil)
    add_rules(nil)
  end

  @doc """
  Adds device ip to the user's sets.
  """
  def add_device(device) do
    get_types()
    |> Enum.each(fn type -> add_to_set(device.user_id, device[type], type) end)
  end

  @doc """
  Adds rule ip to its corresponding sets.
  """
  def add_rule(rule) do
    add_to_set(rule.user_id, rule.destination, proto(rule.destination), rule.action)
  end

  @doc """
  Delete rule destination ip from its corresponding sets.
  """
  def delete_rule(rule) do
    remove_from_set(rule.user_id, rule.destination, proto(rule.destination), rule.action)
  end

  @doc """
  Eliminates device rules from its corresponding sets.
  """
  def delete_device(device) do
    get_types()
    |> Enum.each(fn type -> remove_from_set(device.user_id, device[type], type) end)
  end

  defp remove_from_set(_user_id, nil, _type), do: :no_ip

  defp remove_from_set(user_id, ip, type) do
    get_device_set_name(user_id, type)
    |> delete_elem(ip)
  end

  defp remove_from_set(user_id, ip, type, action) do
    get_dest_set_name(user_id, type, action)
    |> delete_elem(ip)
  end

  defp add_to_set(_user_id, nil, _type), do: :no_ip

  defp add_to_set(user_id, ip, type) do
    get_device_set_name(user_id, type)
    |> add_elem(ip)
  end

  defp add_to_set(user_id, ip, type, action) do
    get_dest_set_name(user_id, type, action)
    |> add_elem(ip)
  end

  defp add_sets(user_id) do
    list_sets(user_id)
    |> Enum.each(&add_set/1)
  end

  defp delete_sets(user_id) do
    list_sets(user_id)
    |> Enum.each(&delete_set/1)
  end

  defp add_rules(user_id) do
    cross(get_types(), get_actions())
    |> Enum.each(fn {type, action} ->
      create_rule(
        type,
        get_device_set_name(user_id, type),
        get_dest_set_name(user_id, type, action),
        action
      )
    end)
  end

  defp delete_rules(user_id) do
    cross(get_types(), get_actions())
    |> Enum.each(fn {type, action} ->
      remove_rule(
        type,
        get_device_set_name(user_id, type),
        get_dest_set_name(user_id, type, action),
        action
      )
    end)
  end

  # xxx: here we could add multiple devices/rules in a single nft call
  def restore({users, devices, rules}) do
    Enum.each(users, &add_user/1)
    Enum.each(devices, &add_device/1)
    Enum.each(rules, &add_rule/1)
  end

  def egress_address do
    case :os.type() do
      {:unix, :linux} ->
        cmd = "ip address show dev #{egress_interface()} | grep 'inet ' | awk '{print $2}'"

        exec!(cmd)
        |> String.trim()
        |> String.split("/")
        |> List.first()

      {:unix, :darwin} ->
        cmd = "ipconfig getifaddr #{egress_interface()}"

        exec!(cmd)
        |> String.trim()

      _ ->
        raise "OS not supported (yet)"
    end
  end

  defp egress_interface do
    Application.fetch_env!(:fz_wall, :egress_interface)
  end

  defp proto(ip) do
    case ip_type("#{ip}") do
      "IPv4" -> "ip"
      "IPv6" -> "ip6"
      "unknown" -> raise "Unknown protocol."
    end
  end
end
