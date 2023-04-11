defmodule Domain.NetworkFixtures do
  alias Domain.Repo
  alias Domain.Network

  def address_attrs(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{address: nil, type: nil})
    {:ok, inet} = Domain.Types.INET.cast(attrs.address)
    type = type(inet.address)
    %{attrs | address: inet, type: type}
  end

  defp type(tuple) when tuple_size(tuple) == 4, do: :ipv4
  defp type(tuple) when tuple_size(tuple) == 8, do: :ipv6

  def create_address(attrs \\ %{}) do
    %Network.Address{}
    |> struct(address_attrs(attrs))
    |> Repo.insert!()
  end
end
