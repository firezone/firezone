defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the nftables CLI.

  Rules operate on the nftables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from Firezone device IPs.
  """

  import FzCommon.CLI
  import FzCommon.FzNet, only: [ip_type: 1, standardized_inet: 1]
  require Logger

  @table_name "firezone"

  @doc """
  Adds nftables rule.
  """
  def add_rule(params) do
    exec!("""
      #{nft()} 'add rule inet #{@table_name} forward #{rule_str(params)}'
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

    # XXX: Do more testing with this method of creating masquerade rules
    for int <- File.ls!("/sys/class/net/") do
      # Masquerade all interfaces except loopback and our own wireguard interface
      if int not in ["lo", wireguard_interface_name()] do
        exec!(
          "#{nft()} 'add rule inet #{@table_name} postrouting oifname " <>
            "#{int} masquerade persistent'"
        )
      end
    end
  end

  def teardown_table do
    if table_exists?() do
      exec!("#{nft()} delete table inet #{@table_name}")
    end
  end

  @doc """
  List currently loaded rules.
  """
  def list_rules do
    exec!("#{nft()} -a list table inet #{@table_name}")
  end

  @doc """
  Deletes nftables rule.
  """
  def delete_rule(params) do
    rule_str = rule_str(params)
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

  defp rule_str({dest, action}), do: "#{rule_match_str(dest)} #{action}"
  defp rule_str({source, dest, action}), do: "#{rule_match_str(source, dest)} #{action}"

  defp rule_match_str(dest), do: "#{proto(dest)} daddr #{standardized_inet(dest)}"

  defp rule_match_str(source, dest) do
    "#{proto(source)} saddr #{standardized_inet(source)} #{rule_match_str(dest)}"
  end
end
