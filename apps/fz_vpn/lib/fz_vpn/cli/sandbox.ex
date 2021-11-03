defmodule FzVpn.CLI.Sandbox do
  @moduledoc """
  Sandbox CLI environment for WireGuard CLI operations.
  """

  require Logger

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
