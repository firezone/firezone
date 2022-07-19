defmodule FzWall.CLI.Helpers.Nft do
  @moduledoc """
  Helper module concering nft commands
  """
  import FzCommon.CLI
  import FzCommon.FzNet, only: [standardized_inet: 1]
  require Logger
  @table_name "firezone"

  @doc """
  Insert a nft rule
  """
  def insert_rule(type, source_set, dest_set, action) do
    exec!("""
      #{nft()} 'insert rule inet #{@table_name} forward #{rule_match_str(type, source_set, dest_set, action)}'
    """)
  end

  @doc """
  Removes a nft rule
  """
  def remove_rule(type, source_set, dest_set, action) do
    delete_rule_matching(rule_match_str(type, source_set, dest_set, action))
  end

  @doc """
  Adds an element from a nft set
  """
  def add_elem(set, ip) do
    exec!("""
      #{nft()} 'add element inet #{@table_name} #{set} { #{standardized_inet(ip)} }'
    """)
  end

  @doc """
  Deletes an element from a nft set
  """
  def delete_elem(set, ip) do
    exec!("""
      #{nft()} 'delete element inet #{@table_name} #{set} { #{standardized_inet(ip)} }'
    """)
  end

  @doc """
  Adds a nft set
  """
  def add_set(set_spec) do
    exec!("""
      #{nft()} 'add set inet #{@table_name} #{set_spec.name} { type #{set_type(set_spec.type)} ; flags interval ; }'
    """)
  end

  @doc """
  Deletes a nft set
  """
  def delete_set(set_spec) do
    exec!("""
      #{nft()} 'delete set inet #{@table_name} #{set_spec.name}'
    """)
  end

  @doc """
  Sets up firezone table.
  """
  def setup_table do
    exec!("#{nft()} create table inet #{@table_name}")
  end

  @doc """
  Sets up firezone chains.
  """
  def setup_chains do
    exec!(
      "#{nft()} 'add chain inet #{@table_name} forward " <>
        "{ type filter hook forward priority 0 ; policy accept ; }'"
    )

    exec!(
      "#{nft()} 'add chain inet #{@table_name} postrouting " <>
        "{ type nat hook postrouting priority 100 ; }'"
    )

    setup_masquerade()
  end

  defp setup_masquerade do
    if masquerade_ipv4?() do
      setup_masquerade(:ipv4)
    end

    if masquerade_ipv6?() do
      setup_masquerade(:ipv6)
    end
  end

  defp setup_masquerade(proto) do
    File.ls!("/sys/class/net/")
    |> Enum.reject(&skip_masquerade_for_interface?/1)
    |> Enum.map(fn int ->
      exec!(
        "#{nft()} 'add rule inet #{@table_name} postrouting oifname " <>
          "#{int} meta nfproto #{proto} masquerade persistent'"
      )
    end)
  end

  defp skip_masquerade_for_interface?(int) do
    int in ["lo", wireguard_interface_name()]
  end

  defp masquerade_ipv4? do
    Application.fetch_env!(:fz_wall, :wireguard_ipv4_masquerade)
  end

  defp masquerade_ipv6? do
    Application.fetch_env!(:fz_wall, :wireguard_ipv6_masquerade)
  end

  @doc """
  Deletes nft tables (This will remove)
  """
  def teardown_table do
    if table_exists?() do
      exec!("#{nft()} delete table inet #{@table_name}")
    end
  end

  defp nft do
    Application.fetch_env!(:fz_wall, :nft_path)
  end

  defp table_exists? do
    cmd = "#{nft()} list table inet #{@table_name}"

    case bash(cmd) do
      {_result, 0} ->
        true

      {error, _exit_code} ->
        if error =~ ~r/No such file or directory|does not exist/ do
          false
        else
          raise """
            Unknown Error from command #{cmd}. Error:
            #{error}
          """
        end
    end
  end

  defp delete_rule_matching(rule_str) do
    rules = exec!("#{nft()} -a list table inet #{@table_name}")

    # When a rule is deleted the others might change handle so we need to
    # re-scan each time.
    case rule_handle_regex(~r/^\s*#{rule_str}.*# handle (?<num>\d+)/m, rules) do
      nil ->
        Logger.warning(
          "Tried to delete a rule with string: #{rule_str} but it wasn't found, might have been removed manually"
        )

      handle ->
        exec!("#{nft()} delete rule inet #{@table_name} forward handle #{handle}")
    end
  end

  defp wireguard_interface_name do
    Application.fetch_env!(:fz_wall, :wireguard_interface_name)
  end

  defp rule_handle_regex(regex, rules) do
    Regex.run(regex, rules, capture: :all_names)
  end

  defp set_type(:ip), do: "ipv4_addr"
  defp set_type(:ip6), do: "ipv6_addr"

  defp rule_match_str(type, nil, dest_set, action) do
    "#{type} daddr @#{dest_set} ct state != established #{action}"
  end

  defp rule_match_str(type, source_set, dest_set, action) do
    "#{type} saddr @#{source_set} #{rule_match_str(type, nil, dest_set, action)}"
  end
end
