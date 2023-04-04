defmodule Domain.Encrypted.Binary do
  @moduledoc """
  Configures how to encrpyt Binaries to the DB.
  """

  use Cloak.Ecto.Binary, vault: Domain.Vault
end
