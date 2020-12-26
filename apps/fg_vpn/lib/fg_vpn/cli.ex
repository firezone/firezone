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

  # Outputs the privkey, then pubkey on the next line
  @genkey_cmd "wg genkey | tee >(wg pubkey)"

  @doc """
  Finds default egress interface on a Linux box.
  """
  def default_interface do
    case :os.type() do
      {:unix, :linux} ->
        exec(@default_interface_cmd)
        |> String.split()
        |> List.first()

      {:unix, :darwin} ->
        # XXX: Figure out what it means to have macOS as a host?
        "en0"
    end
  end

  @doc """
  Calls wg genkey
  """
  def genkey do
    [privkey, pubkey] =
      exec(@genkey_cmd)
      |> String.trim()
      |> String.split("\n")

    {privkey, pubkey}
  end

  def pubkey(privkey) when is_nil(privkey), do: nil

  def pubkey(privkey) when is_binary(privkey) do
    exec("echo #{privkey} | wg pubkey")
    |> String.trim()
  end

  defp exec(cmd) do
    case System.cmd("bash", ["-c", cmd]) do
      {result, 0} ->
        result

      {error, _} ->
        raise "Error executing command: #{error}"
    end
  end
end
