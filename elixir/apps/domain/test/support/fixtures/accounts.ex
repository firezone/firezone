defmodule Domain.Fixtures.Accounts do
  use Domain.Fixture
  alias Domain.Accounts

  def account_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "acc-#{unique_integer()}"
    })
  end

  def create_account(attrs \\ %{}) do
    attrs = account_attrs(attrs)
    {:ok, account} = Accounts.create_account(attrs)
    account
  end
end
