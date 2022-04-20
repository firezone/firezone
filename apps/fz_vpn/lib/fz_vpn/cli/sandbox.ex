defmodule FzVpn.CLI.Sandbox do
  @moduledoc """
  Sandbox CLI environment for WireGuard CLI operations used in
  dev and test modes.
  """

  alias FzVpn.Config
  require Logger

  @show_dump """
  0A+FvaRbBjKan9hyjolIpjpwaz9rguSeNCXNtoOiLmg=	7E8wSJ2ue1l2cRm/NsqkFfmb0HZxc+3Dg373BVcMxx4=	51820	off
  +wEYaT5kNg7mp+KbDMjK0FkQBtrN8RprHxudAgS0vS0=	(none)	140.82.48.115:54248	10.3.2.7/32,fd00::3:2:7/128	1650286790	14161600	3668160	off
  JOvewkquusVzBHIRjvq32gE4rtsmDKyGh8ubhT4miAY=	(none)	149.28.197.67:44491	10.3.2.8/32,fd00::3:2:8/128	1650286747	177417128	138272552	off
  """
  @show_latest_handshakes "4 seconds ago"
  @show_persistent_keepalive "every 25 seconds"
  @show_transfer "4.60 MiB received, 59.21 MiB sent"
  @default_returned ""

  def setup, do: @default_returned
  def teardown, do: @default_returned

  def exec!(_cmd) do
    @default_returned
  end

  def set(_conf_str) do
    @default_returned
  end

  def remove_peer(public_key) do
    Config.delete_psk(public_key)
    @default_returned
  end

  def show_latest_handshakes, do: @show_latest_handshakes
  def show_persistent_keepalive, do: @show_persistent_keepalive
  def show_transfer, do: @show_transfer
  def show_dump, do: @show_dump
end
