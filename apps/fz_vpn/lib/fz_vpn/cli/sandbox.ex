defmodule FzVpn.CLI.Sandbox do
  @moduledoc """
  Sandbox CLI environment for WireGuard CLI operations used in
  dev and test modes.
  """

  alias FzVpn.Config
  require Logger

  @wg_show """
  interface: wg-firezone
  public key: Kewtu/udoH+mZzcS0vixCXa8fiMNcurlNy+oQzLZiQk=
  private key: (hidden)
  listening port: 51820

  peer: 1RSUaL+er3+HJM7JW2u5uZDIFNNJkw2nV7dnZyOAK2k=
    endpoint: 73.136.58.38:55433
    allowed ips: 10.3.2.2/32, fd00:3:2::2/128
    latest handshake: 56 minutes, 14 seconds ago
    transfer: 1.21 MiB received, 39.30 MiB sent
  """
  @show_dump """
  0A+FvaRbBjKan9hyjolIpjpwaz9rguSeNCXNtoOiLmg=	7E8wSJ2ue1l2cRm/NsqkFfmb0HZxc+3Dg373BVcMxx4=	51820	off
  +wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0=	(none)	140.82.48.115:54248	10.3.2.7/32,fd00::3:2:7/128	1650286790	14161600	3668160	off
  JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY=	(none)	149.28.197.67:44491	10.3.2.8/32,fd00::3:2:8/128	1650286747	177417128	138272552	off
  """
  @show_latest_handshakes "4 seconds ago"
  @show_persistent_keepalive "every 25 seconds"
  @show_transfer "4.60 MiB received, 59.21 MiB sent"
  @default_returned ""

  def interface_address, do: "eth0"
  def setup, do: @default_returned
  def teardown, do: @default_returned
  def pubkey(_privkey), do: rand_key()

  def exec!(_cmd) do
    @default_returned
  end

  def set(_conf_str) do
    @default_returned
  end

  def remove_peers do
    @wg_show
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "peer")
    end)
    |> Enum.map(fn line ->
      String.replace_leading(line, "peer: ", "")
    end)
    |> Enum.each(fn public_key ->
      remove_peer(public_key)
    end)
  end

  def remove_peer(public_key) do
    Config.delete_psk(public_key)
    @default_returned
  end

  def show_latest_handshakes, do: @show_latest_handshakes
  def show_persistent_keepalive, do: @show_persistent_keepalive
  def show_transfer, do: @show_transfer
  def show_dump, do: @show_dump

  # Generate extremely fake keys in Sandbox mode
  defp rand_key, do: :crypto.strong_rand_bytes(32) |> Base.encode64()
end
