defmodule FgVpn.CLI do
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

  @default_interface_cmd "route | grep '^default' | grep -o '[^ ]*$'"

  @doc """
  Finds default egress interface on a Linux box.
  """
  def default_interface do
    case :os.type() do
      {:unix, :linux} ->
        case System.cmd("sh", ["-c", @default_interface_cmd]) do
          {result, 0} ->
            result
            |> String.split()
            |> List.first()

          {_error, _} ->
            raise "Could not determine default egress interface from `#{@default_interface_cmd}`"
        end

      {:unix, :darwin} ->
        # XXX: Figure out what it means to have macOS as a host?
        "en0"
    end
  end

  @doc """
  Calls wg genkey
  """
  def gen_privkey do
  end
end
