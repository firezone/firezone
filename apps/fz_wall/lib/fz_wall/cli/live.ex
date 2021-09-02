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
    exec!("#{nft()} add table ip #{@table_name}")

    exec!(
      "#{nft()} 'add chain ip #{@table_name} forward { type filter hook forward priority 0 ; }'"
    )

    exec!("#{nft()} 'add rule ip #{@table_name} forward counter accept'")
  end

  @doc """
  Flushes and removes the FireZone nftables table and base chain.
  """
  def teardown do
    exec!("#{nft()} delete table ip #{@table_name}")
  end

  @doc """
  Adds nftables rule.
  """
  def add_rule({dest, action}) do
    exec!("#{nft()} 'add rule ip #{@table_name} forward ip daddr #{dest} #{action}'")
  end

  @doc """
  Deletes nftables rule.
  """
  def delete_rule_spec({dest, action} = rule_spec) do
    case get_rule_handle("ip daddr #{dest} #{action}") do
      {:ok, handle_num} ->
        exec!("#{nft()} delete rule #{@table_name} forward handle #{handle_num}")

      {:error, cmd_output} ->
        raise("""
          ######################################################
          Could not get handle to delete rule!
          Rule spec: #{rule_spec}

          Current chain:
          #{cmd_output}
          ######################################################
        """)
    end
  end

  def get_rule_handle(rule_str) do
    cmd_output = exec!("#{nft()} list table #{@table_name}")

    case rule_handle_regex(~r/#{rule_str}.*# handle (?<num>\d+)/, cmd_output) do
      [handle] ->
        {:ok, handle}

      [] ->
        {:error, cmd_output}
    end
  end

  defp rule_handle_regex(regex, cmd_output) do
    Regex.run(regex, cmd_output, capture: :all_names)
  end

  def restore(_rules) do
    # XXX: Implement me
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
