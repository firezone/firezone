defmodule FzVpn.Config do
  @moduledoc """
  Functions for managing the WireGuard configuration.
  """

  require Logger

  # Render peers list into server config
  def render(config) do
    Enum.join(
      for {public_key, %{allowed_ips: allowed_ips, preshared_key: preshared_key}} <- config do
        if is_nil(preshared_key) do
          "peer #{public_key} allowed-ips #{allowed_ips}"
        else
          write_psk(public_key, preshared_key)

          "peer #{public_key} allowed-ips #{allowed_ips} preshared-key #{psk_filepath(public_key)}"
        end
      end,
      " "
    )
  end

  def write_psk(public_key, preshared_key) do
    # Sets proper file mode before key is written
    File.touch!(psk_filepath(public_key))
    File.chmod!(psk_filepath(public_key), 0o660)
    File.write!(psk_filepath(public_key), preshared_key)
  end

  def delete_psk(public_key) do
    case File.rm(psk_filepath(public_key)) do
      :ok ->
        :ok

      _ ->
        Logger.warn("""
        public_key #{public_key} at path #{psk_filepath(public_key)} \
        seems to have already been removed.
        """)
    end
  end

  def psk_filepath(nil), do: raise("Error! public_key unexpectedly nil")

  def psk_filepath(public_key) do
    "#{psk_dir()}/#{psk_filename(public_key)}"
  end

  defp psk_dir do
    Application.fetch_env!(:fz_vpn, :wireguard_psk_dir)
  end

  defp psk_filename(public_key) do
    :crypto.hash(:sha256, public_key)
    |> Base.encode16()
    |> String.downcase()
  end
end
