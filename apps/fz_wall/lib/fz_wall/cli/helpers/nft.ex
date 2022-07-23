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
  def insert_filter_rule(chain, type, dest_set, action, layer4) do
    exec!("""
      #{nft()} 'insert rule inet #{@table_name} #{chain} #{rule_filter_match_str(type, dest_set, action, layer4)}'
    """)
  end

  @doc """
  Insert a nft rule
  """
  def insert_dev_rule(ip_type, source_set, jump_chain) do
    exec!("""
      #{nft()} 'insert rule inet #{@table_name} #{rule_dev_match_str(ip_type, source_set, jump_chain)}'
    """)
  end

  def remove_dev_rule(ip_type, source_set, jump_chain) do
    delete_rule_matching(rule_dev_match_str(ip_type, source_set, jump_chain))
  end

  def add_filter_elem(set, ip, nil, nil) do
    exec!("""
      #{nft()} 'add element inet #{@table_name} #{set} { #{standardized_inet(ip)} }'
    """)
  end

  def add_filter_elem(set, ip, proto, ports) do
    exec!("""
      #{nft()} 'add element inet #{@table_name} #{set} { #{standardized_inet(ip)} . #{proto} . #{ports} }'
    """)
  end

  @doc """
  Adds an element from a nft set
  """
  def add_dev_elem(set, ip) do
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

  def delete_elem(set, ip, nil, ports) do
    exec!("""
      #{nft()} 'delete element inet #{@table_name} #{set} { #{standardized_inet(ip)} . #{ports} }'
    """)
  end

  def delete_elem(set, ip, proto, ports) do
    exec!("""
      #{nft()} 'delete element inet #{@table_name} #{set} { #{standardized_inet(ip)} . #{proto} . #{ports} }'
    """)
  end

  @doc """
  Adds a nft set
  """
  def add_dev_set(set_spec) do
    exec!("""
      #{nft()} 'add set inet #{@table_name} #{set_spec.name} { type #{dev_set_type(set_spec.ip_type)} ; flags interval ; }'
    """)
  end

  def remove_dev_set(set_spec) do
    exec!("""
      #{nft()} 'add set inet #{@table_name} #{set_spec.name}'
    """)
  end

  def add_filter_set(set_spec) do
    exec!("""
      #{nft()} 'add set inet #{@table_name} #{set_spec.name} { type #{filter_set_type(set_spec.ip_type, set_spec.layer4)} ; flags interval ; }'
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

  @doc """
  Adds a regular nftable chain
  """
  def add_chain(chain_name) do
    exec!("#{nft()} 'add chain inet #{@table_name} #{chain_name}'")
  end

  def delete_chain(chain_name) do
    exec!("#{nft()} 'delete chain inet #{@table_name} #{chain_name}'")
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

  defp filter_set_type(:ip, false), do: "ipv4_addr"
  defp filter_set_type(:ip6, false), do: "ipv6_addr"
  defp filter_set_type(:ip, true), do: "ipv4_addr . inet_proto . inet_service"
  defp filter_set_type(:ip6, true), do: "ipv6_addr . inet_proto . inet_service"

  defp dev_set_type(:ip), do: "ipv4_addr"
  defp dev_set_type(:ip6), do: "ipv6_addr"

  defp rule_filter_match_str(type, dest_set, action, false) do
    "#{type} daddr @#{dest_set} ct state != established #{action}"
  end

  defp rule_filter_match_str(type, dest_set, action, true) do
    "#{type} daddr . meta l4proto . th dport @#{dest_set} ct state != established #{action}"
  end

  defp rule_dev_match_str(ip_type, source_set, jump_chain) do
    "forward #{ip_type} saddr @#{source_set} jump #{jump_chain}"
  end
end
