defmodule Domain.Types.EncryptedMap do
  use Cloak.Ecto.Map, vault: Domain.Vault
end
