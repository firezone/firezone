defmodule Domain.Fixtures.Accounts do
  use Domain.Fixture
  alias Domain.Accounts

  def account_attrs(attrs \\ %{}) do
    unique_num = unique_integer()

    Enum.into(attrs, %{
      name: "acc-#{unique_num}",
      slug: "acc_#{unique_num}"
    })
  end

  def create_account(attrs \\ %{}) do
    attrs = account_attrs(attrs)
    {:ok, account} = Accounts.create_account(attrs)
    account
  end
end
