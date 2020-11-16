defmodule FgVpn.WGCLI do
  @moduledoc """
  Wraps command-line functionality of WireGuard for our purposes.

  Application startup:
    - wg syncconf

  Consumed events:
    - add device:
      1. start listening for new connections
      2. send pubkey when device connects
      3. when verification received from fg_http, add config entry

    - remove device:
      1. disconnect device if connected
      2. remove configuration entry

  Produced events:
    - client connects:
      1. send IP, connection time to FgHttp
    - change config

  Helpers:
    - render_conf: re-renders configuration file (peer configurations specifically)
    - sync_conf: calls "wg syncconf"
  """
end
