defmodule FzVpn.CLI.Sandbox do
  @moduledoc """
  Sandbox CLI environment for WireGuard CLI operations.
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
  def exec!(_cmd), do: @default_returned
  def set(_conf_str), do: @default_returned
  def delete_peer(_pubkey), do: @default_returned
  def show_latest_handshakes, do: @show_latest_handshakes
  def show_persistent_keepalives, do: @show_persistent_keepalives
  def show_transfer, do: @show_transfer

  # Generate extremely fake keys in Sandbox mode
  defp rand_key, do: :crypto.strong_rand_bytes(32) |> Base.encode64()
end
