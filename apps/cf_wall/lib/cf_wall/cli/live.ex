defmodule CfWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the iptables CLI.

  Rules operate on the iptables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from CloudFire device IPs.

  Note that iptables chains and rules are mutually exclusive between IPv4 and IPv6.
  """

  import CfCommon.CLI

  @setup_chain_cmd "iptables -N cloudfire && iptables6 -N cloudfire"
  @teardown_chain_cmd "iptables -F cloudfire &&\
                       iptables -X cloudfire &&\
                       iptables6 -F cloudfire &&\
                       iptables6 -X cloudfire"

  @doc """
  Sets up the CloudFire iptables chain.
  """
  def setup do
    exec!(@setup_chain_cmd)
  end

  @doc """
  Flushes and removes the CloudFire iptables chain.
  """
  def teardown do
    exec!(@teardown_chain_cmd)
  end

  @doc """
  Adds iptables rule.
  """
  def add_rule({4, s, d, :deny}) do
    exec!("iptables -A cloudfire -s #{s} -d #{d} -j DROP")
  end

  def add_rule({4, s, d, :allow}) do
    exec!("iptables -A cloudfire -s #{s} -d #{d} -j ACCEPT")
  end

  def add_rule({6, s, d, :deny}) do
    exec!("iptables6 -A cloudfire -s #{s} -d #{d} -j DROP")
  end

  def add_rule({6, s, d, :allow}) do
    exec!("iptables6 -A cloudfire -s #{s} -d #{d} -j ACCEPT")
  end

  @doc """
  Deletes iptables rule.
  """
  def delete_rule({4, s, d, :deny}) do
    exec!("iptables -D cloudfire -s #{s} -d #{d} -j DROP")
  end

  def delete_rule({4, s, d, :allow}) do
    exec!("iptables -D cloudfire -s #{s} -d #{d} -j ACCEPT")
  end

  def delete_rule({6, s, d, :deny}) do
    exec!("iptables6 -D cloudfire -s #{s} -d #{d} -j DROP")
  end

  def delete_rule({6, s, d, :allow}) do
    exec!("iptables6 -D cloudfire -s #{s} -d #{d} -j ACCEPT")
  end
end
