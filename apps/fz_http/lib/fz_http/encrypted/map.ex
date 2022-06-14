defmodule FzHttp.Encrypted.Map do
  @moduledoc """
  Configures how to encrpyt Maps to the DB.
  """

  use Cloak.Ecto.Map, vault: FzHttp.Vault
end
