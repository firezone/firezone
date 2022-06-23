defmodule FzVpn.Keypair do
  @moduledoc """
  Utilities for persisting / generating keypairs.
  """

  def load_or_generate_private_key do
    path = Application.fetch_env!(:fz_vpn, :wireguard_private_key_path)

    private_key =
      if File.exists?(path) && File.stat!(path).size > 0 do
        File.read!(path)
        |> String.trim()
      else
        key = Wireguardex.generate_private_key()
        write_private_key(path, key)
        key
      end

    set_public_key(private_key)
    private_key
  end

  defp set_public_key(private_key) do
    {:ok, public_key} = Wireguardex.get_public_key(private_key)
    Application.put_env(:fz_vpn, :wireguard_public_key, public_key, persistent: true)
  end

  defp write_private_key(path, private_key) do
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, private_key)
  end
end
