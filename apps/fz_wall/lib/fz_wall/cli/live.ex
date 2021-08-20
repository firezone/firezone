defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the iptables CLI.

  Rules operate on the iptables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from FireZone device IPs.

  Note that iptables chains and rules are mutually exclusive between IPv4 and IPv6.
  """

  import FzCommon.CLI

  @egress_interface_cmd "route | grep '^default' | grep -o '[^ ]*$'"
  @setup_chain_cmd "iptables -N firezone && iptables6 -N firezone"
  @teardown_chain_cmd "iptables -F firezone &&\
                       iptables -X firezone &&\
                       iptables6 -F firezone &&\
                       iptables6 -X firezone"

  @doc """
  Sets up the FireZone iptables chain.
  """
  def setup do
    exec!(@setup_chain_cmd)
  end

  @doc """
  Flushes and removes the FireZone iptables chain.
  """
  def teardown do
    exec!(@teardown_chain_cmd)
  end

  @doc """
  Adds iptables rule.
  """
  def add_rule({4, s, d, :deny}) do
    exec!("iptables -A firezone -s #{s} -d #{d} -j DROP")
  end

  def add_rule({4, d, :deny}) do
    exec!("iptables -A firezone -d #{d} -j DROP")
  end

  def add_rule({4, s, d, :allow}) do
    exec!("iptables -A firezone -s #{s} -d #{d} -j ACCEPT")
  end

  def add_rule({6, s, d, :deny}) do
    exec!("iptables6 -A firezone -s #{s} -d #{d} -j DROP")
  end

  def add_rule({6, s, d, :allow}) do
    exec!("iptables6 -A firezone -s #{s} -d #{d} -j ACCEPT")
  end

  @doc """
  Deletes iptables rule.
  """
  def delete_rule({4, s, d, :deny}) do
    exec!("iptables -D firezone -s #{s} -d #{d} -j DROP")
  end

  def delete_rule({4, s, d, :allow}) do
    exec!("iptables -D firezone -s #{s} -d #{d} -j ACCEPT")
  end

  def delete_rule({6, s, d, :deny}) do
    exec!("iptables6 -D firezone -s #{s} -d #{d} -j DROP")
  end

  def delete_rule({6, s, d, :allow}) do
    exec!("iptables6 -D firezone -s #{s} -d #{d} -j ACCEPT")
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
end
