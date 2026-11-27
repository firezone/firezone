defmodule Portal.DeviceCA.Local do
  @moduledoc """
  Keeps each account's device CA key in this portal's database.
  """
  @behaviour Portal.DeviceCA

  @impl true
  def create_key(_account_id) do
    {:ECPrivateKey, _version, _private, parameters, point, _attributes} =
      private_key = :public_key.generate_key({:namedCurve, :secp256r1})

    {:ok,
     %{
       key_id: nil,
       private_key: :public_key.der_encode(:ECPrivateKey, private_key),
       public_key: {{:ECPoint, point}, parameters}
     }}
  end

  @impl true
  def sign(%{private_key: private_key}, digest) when is_binary(private_key) do
    {:ok, :public_key.sign({:digest, digest}, :sha256, :public_key.der_decode(:ECPrivateKey, private_key))}
  end

  def sign(_key, _digest), do: {:error, :unknown_key}

  @impl true
  def delete_key(_account_id), do: :ok
end
