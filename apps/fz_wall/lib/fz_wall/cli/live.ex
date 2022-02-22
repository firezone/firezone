defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the nftables CLI.

  Rules operate on the nftables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from Firezone tunnel IPs.
  """

  import FzCommon.CLI
  import FzCommon.FzNet, only: [ip_type: 1, standardized_inet: 1]
  require Logger

  @table_name "firezone"

  @doc """
  Adds nftables rule.
  """
  def add_rule({dest, action}) do
    exec!("""
      #{nft()} 'add rule inet #{@table_name} forward\
      #{proto(dest)} daddr #{standardized_inet(dest)} #{action}'
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
      "#{nft()} 'add chain inet firezone forward " <>
        "{ type filter hook forward priority 0 ; policy accept ; }'"
    )

    exec!(
      "#{nft()} 'add chain inet firezone postrouting " <>
        "{ type nat hook postrouting priority 100 ; }'"
    )

    # XXX: Do more testing with this method of creating masquerade rules
    for int <- File.ls!("/sys/class/net/") do
      # Masquerade all interfaces except loopback and our own wireguard interface
      if int not in ["lo", wireguard_interface_name()] do
        exec!(
          "#{nft()} 'add rule inet firezone postrouting oifname " <>
            "#{int} masquerade random,persistent'"
        )
      end
    end
  end

  def teardown_table do
    if table_exists?() do
      exec!("#{nft()} delete table inet firezone")
    end
  end

  @doc """
  List currently loaded rules.
  """
  def list_rules do
    exec!("#{nft()} -a list table inet firezone")
  end

  @doc """
  Deletes nftables rule.
  """
  def delete_rule({dest, action}) do
    rule_str = "#{proto(dest)} daddr #{standardized_inet(dest)} #{action}"
    rules = exec!("#{nft()} -a list table inet #{@table_name}")

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
        exec!("#{nft()} delete rule inet #{@table_name} forward handle #{handle}")
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

  defp rule_handle_regex(regex, rules) do
    Regex.run(regex, rules, capture: :all_names)
  end

  defp egress_interface do
    Application.fetch_env!(:fz_wall, :egress_interface)
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
        if String.contains?(error, "Error: No such file or directory") do
          false
        else
          raise """
            Unknown Error from command #{cmd}. Error:
            #{error}
          """
        end
    end
  end

  defp wireguard_interface_name do
    Application.fetch_env!(:fz_wall, :wireguard_interface_name)
  end

  defp proto(dest) do
    case ip_type("#{dest}") do
      "IPv4" -> "ip"
      "IPv6" -> "ip6"
      "unknown" -> raise "Unknown protocol."
    end
  end
end
