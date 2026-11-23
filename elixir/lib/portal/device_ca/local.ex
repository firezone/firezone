defmodule Portal.DeviceCA.Local do
  @moduledoc """
  A software key per account for a portal without Key Vault. The private key is kept in the
  key id, encrypted and signed with a key derived from the tokens key base, so a new key base
  invalidates every device CA.
  """
  @behaviour Portal.DeviceCA

  @prefix "local:"

  @impl true
  def create_key(_account_id) do
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} =
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    der = :public_key.der_encode(:RSAPrivateKey, private_key)
    {secret, sign_secret} = secrets()
    key_id = @prefix <> Plug.Crypto.MessageEncryptor.encrypt(der, secret, sign_secret)

    {:ok, %{key_id: key_id, public_key: {:RSAPublicKey, modulus, exponent}}}
  end

  @impl true
  def delete_key(_account_id), do: :ok

  @impl true
  def sign(@prefix <> encrypted, digest) do
    {secret, sign_secret} = secrets()

    case Plug.Crypto.MessageEncryptor.decrypt(encrypted, secret, sign_secret) do
      {:ok, der} ->
        private_key = :public_key.der_decode(:RSAPrivateKey, der)
        {:ok, :public_key.sign({:digest, digest}, :sha256, private_key)}

      :error ->
        {:error, :unknown_key}
    end
  end

  def sign(_key_id, _digest), do: {:error, :unknown_key}

  defp secrets do
    key_base = Portal.Config.fetch_env!(:portal, Portal.Tokens) |> Keyword.fetch!(:key_base)

    {Plug.Crypto.KeyGenerator.generate(key_base, "device-ca encryption"),
     Plug.Crypto.KeyGenerator.generate(key_base, "device-ca signing")}
  end
end
