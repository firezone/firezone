defmodule Portal.DeviceCA.Local do
  @moduledoc """
  Keeps each account's device CA key in this portal's database.
  """
  @behaviour Portal.DeviceCA

  @impl true
  def create_key(_account_id) do
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} =
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    {:ok,
     %{
       key_id: nil,
       private_key: :public_key.der_encode(:RSAPrivateKey, private_key),
       public_key: {:RSAPublicKey, modulus, exponent}
     }}
  end

  @impl true
  def sign(%{private_key: private_key}, digest) when is_binary(private_key) do
    {:ok, :public_key.sign({:digest, digest}, :sha256, :public_key.der_decode(:RSAPrivateKey, private_key))}
  end

  def sign(_key, _digest), do: {:error, :unknown_key}

  @impl true
  def delete_key(_account_id), do: :ok
end
