defmodule Domain.Accounts.Account do
  use Domain, :schema

  schema "accounts" do
    field :name, :string
    field :slug, :string

    timestamps()
  end
end
