defmodule Domain.AccountsFixtures do
  alias Domain.Accounts

  def account_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "acc-#{counter()}"
    })
  end

  def create_account(attrs \\ %{}) do
    attrs = account_attrs(attrs)
    {:ok, account} = Accounts.create_account(attrs)
    account
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
