defmodule FzVpn.CLI.Sandbox do
  @moduledoc """
  Sandbox CLI environment for WireGuard CLI operations.
  """

  require Logger

  @wg_show """
  interface: wg-firezone
  public key: Kewtu/udoH+mZzcS0vixCXa8fiMNcurlNy+oQzLZiQk=
  private key: (hidden)
  listening port: 51820

  peer: 1RSUaL+er3+HJM7JW2u5uZDIFNNJkw2nV7dnZyOAK2k=
    endpoint: 73.136.58.38:55433
    allowed ips: 10.3.2.2, fd00:3:2::2
    latest handshake: 56 minutes, 14 seconds ago
    transfer: 1.21 MiB received, 39.30 MiB sent
  """
  @show_latest_handshakes "4 seconds ago"
  @show_persistent_keepalives "every 25 seconds"
  @show_transfer "4.60 MiB received, 59.21 MiB sent"
  @default_returned ""

  def interface_address, do: "eth0"
  def setup, do: @default_returned
  def teardown, do: @default_returned
  def genkey, do: {rand_key(), rand_key()}
  def pubkey(_privkey), do: rand_key()

  def exec!(cmd) do
    Logger.debug("`exec!` called with #{cmd}")
    @default_returned
  end

  def set(conf_str) do
    Logger.debug("`set` called with #{conf_str}")
    @default_returned
  end

  def delete_peers do
    @wg_show
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "peer")
    end)
    |> Enum.map(fn line ->
      String.replace_leading(line, "peer: ", "")
    end)
    |> Enum.each(fn pubkey ->
      delete_peer(pubkey)
    end)
  end

  def delete_peer(pubkey) do
    Logger.debug("`delete_peer` called with #{pubkey}")
    @default_returned
  end

  def set_peer(pubkey, allowed_ips) do
    Logger.debug("`set_peer` called with #{pubkey}, #{allowed_ips}")
    @default_returned
  end

  def show_latest_handshakes, do: @show_latest_handshakes
  def show_persistent_keepalives, do: @show_persistent_keepalives
  def show_transfer, do: @show_transfer

  # Generate extremely fake keys in Sandbox mode
  defp rand_key, do: :crypto.strong_rand_bytes(32) |> Base.encode64()
end
