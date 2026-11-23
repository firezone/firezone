defmodule Portal.DeviceCA.Local do
  @moduledoc """
  Signs for every account with the one key in `DEVICE_CA_PRIVATE_KEY`.
  """
  @behaviour Portal.DeviceCA

  @key_id "local"

  @impl true
  def create_key(_account_id) do
    with {:ok, {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other}} <-
           private_key() do
      {:ok, %{key_id: @key_id, public_key: {:RSAPublicKey, modulus, exponent}}}
    end
  end

  @impl true
  def delete_key(_account_id), do: :ok

  @impl true
  def sign(@key_id, digest) do
    with {:ok, private_key} <- private_key() do
      {:ok, :public_key.sign({:digest, digest}, :sha256, private_key)}
    end
  end

  def sign(_key_id, _digest), do: {:error, :unknown_key}

  defp private_key do
    case Portal.Config.fetch_env!(:portal, :device_ca_private_key) do
      pem when pem in [nil, ""] -> {:error, :not_configured}
      pem -> decode(pem)
    end
  end

  defp decode(pem) do
    case :public_key.pem_decode(pem) do
      [entry] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPrivateKey, _, modulus, _, _, _, _, _, _, _, _} = key when modulus > 0 -> {:ok, key}
          _other -> {:error, :invalid_key}
        end

      _other ->
        {:error, :invalid_key}
    end
  rescue
    _exception -> {:error, :invalid_key}
  end
end
