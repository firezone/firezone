defmodule Domain.Encrypted.Map do
  @moduledoc """
  Configures how to encrpyt Maps to the DB.
  """

  use Cloak.Ecto.Map, vault: Domain.Vault
end
