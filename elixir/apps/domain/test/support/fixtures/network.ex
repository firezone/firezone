defmodule Domain.Fixtures.Network do
  use Domain.Fixture
  alias Domain.Network

  def address_attrs(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{account_id: nil, address: nil, type: nil})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, inet} = Domain.Types.INET.cast(attrs.address)
    type = type(inet.address)
    %{attrs | address: inet, type: type, account_id: account.id}
  end

  defp type(tuple) when tuple_size(tuple) == 4, do: :ipv4
  defp type(tuple) when tuple_size(tuple) == 8, do: :ipv6

  def create_address(attrs \\ %{}) do
    %Network.Address{}
    |> struct(address_attrs(attrs))
    |> Repo.insert!()
  end
end
