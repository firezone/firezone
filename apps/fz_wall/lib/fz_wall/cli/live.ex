defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the nftables CLI.

  Rules operate on the nftables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from FireZone device IPs.
  """

  import FzCommon.CLI
  require Logger

  @table_name "firezone"
  @egress_interface_cmd "route | grep '^default' | grep -o '[^ ]*$'"

  @doc """
  Sets up the FireZone nftables table, base chain, and counts traffic
  "forward" is the Netfilter hook we want to tie into.
  """
  def setup do
    # Start with a blank slate
    teardown()

    for protocol <- ["ip", "ip6"] do
      exec!("#{nft()} add table #{protocol} #{@table_name}")

      exec!(
        "#{nft()} 'add chain #{protocol} #{@table_name} forward { type filter hook forward priority 0 ; }'"
      )

      exec!("#{nft()} 'add rule #{protocol} #{@table_name} forward counter accept'")
    end
  end

  @doc """
  Flushes and removes the FireZone nftables table and base chain.
  """
  def teardown do
    for protocol <- ["ip", "ip6"] do
      exec!("#{nft()} delete table #{protocol} #{@table_name}")
    end
  end

  @doc """
  Adds nftables rule.
  """
  def add_rule({proto, dest, action}) do
    exec!("""
      #{nft()} 'add rule #{proto} #{@table_name} forward\
      #{proto} daddr #{standardized_dest(dest)} #{action}'
    """)
  end

  @doc """
  List currently loaded rules.
  """
  def list_rules do
    exec!("#{nft()} -a list table ip firezone")
    exec!("#{nft()} -a list table ip6 firezone")
  end

  @doc """
  Deletes nftables rule.
  """
  def delete_rule({proto, dest, action}) do
    rule_str = "#{proto} daddr #{standardized_dest(dest)} #{action}"
    rules = exec!("#{nft()} -a list table #{proto} #{@table_name}")

    case rule_handle_regex(~r/#{rule_str}.*# handle (?<num>\d+)/, rules) do
      nil ->
        raise("""
          ######################################################
          Could not get handle to delete rule!
          Rule spec: #{rule_str}

          Current rules:
          #{rules}
          ######################################################
        """)

      [handle] ->
        exec!("#{nft()} delete rule #{proto} #{@table_name} forward handle #{handle}")
    end
  end

  @doc """
  Restores rules.
  """
  def restore(rules) do
    # XXX: Priority?
    for rule_spec <- rules do
      add_rule(rule_spec)
    end
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

  @doc """
  Standardized IP addresses and CIDR ranges so that we can
  parse them out of the nftables rulesets.
  """
  def standardized_dest(dest) do
    if String.contains?(dest, "/") do
      dest
      |> InetCidr.parse()
      |> InetCidr.to_string()
    else
      {:ok, addr} = dest |> String.to_charlist() |> :inet.parse_address()
      :inet.ntoa(addr) |> List.to_string()
    end
  end

  defp rule_handle_regex(regex, rules) do
    Regex.run(regex, rules, capture: :all_names)
  end

  defp egress_interface do
    case :os.type() do
      {:unix, :linux} ->
        exec!(@egress_interface_cmd)
        |> String.split()
        |> List.first()

      {:unix, :darwin} ->
        # XXX: Figure out what it means to have macOS as a host?
        "en0"
    end
  end

  defp nft do
    Application.fetch_env!(:fz_wall, :nft_path)
  end
end
