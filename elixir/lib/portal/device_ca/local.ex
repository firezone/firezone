defmodule Portal.DeviceCA.Local do
  @moduledoc """
  A software key per account, derived from the tokens key base, for a portal without Key Vault.
  Nothing is stored: the same key base gives the same key, and a new key base invalidates every
  device certificate.
  """
  @behaviour Portal.DeviceCA

  # The order of the P-256 group.
  @order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @impl true
  def create_key(account_id) do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1, private_key(account_id))
    {:ok, %{key_id: "local:" <> account_id, public_key: public_key}}
  end

  @impl true
  def delete_key(_account_id), do: :ok

  @impl true
  def sign("local:" <> account_id, digest) do
    der = :crypto.sign(:ecdsa, :sha256, {:digest, digest}, [private_key(account_id), :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    {:ok, <<r::256, s::256>>}
  end

  def sign(_key_id, _digest), do: {:error, :unknown_key}

  defp private_key(account_id, counter \\ 0) do
    key_base = Portal.Config.fetch_env!(:portal, Portal.Tokens) |> Keyword.fetch!(:key_base)
    candidate = :crypto.mac(:hmac, :sha256, key_base, "device-ca:#{account_id}:#{counter}")

    case :binary.decode_unsigned(candidate) do
      scalar when scalar > 0 and scalar < @order -> candidate
      _out_of_range -> private_key(account_id, counter + 1)
    end
  end
end
