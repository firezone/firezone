defmodule Domain.Types.EncryptedString do
  @moduledoc """
  A type that encrypts and decrypts string and dumps it to Base64-encoded string.
  """
  use Cloak.Ecto.Type, vault: Domain.Vault

  @impl Ecto.Type
  def embed_as(_format), do: :dump

  @impl Ecto.Type
  def dump(value) do
    with {:ok, value} <- cast(value),
         value <- before_encrypt(value),
         {:ok, value} <- encrypt(value) do
      {:ok, Base.encode64(value)}
    else
      _other ->
        :error
    end
  end

  @impl Ecto.Type
  def load(nil) do
    {:ok, nil}
  end

  def load(value) do
    with {:ok, value} <- Base.decode64(value),
         {:ok, value} <- decrypt(value) do
      {:ok, after_decrypt(value)}
    else
      _other ->
        :error
    end
  end
end
