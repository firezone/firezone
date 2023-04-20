defmodule Domain.Accounts.Account do
  use Domain, :schema

  schema "accounts" do
    field :name, :string

    timestamps()
  end
end
