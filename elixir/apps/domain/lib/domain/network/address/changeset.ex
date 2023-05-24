defmodule Domain.Network.Address.Changeset do
  use Domain, :changeset
  alias Domain.Network.Address

  def create_changeset(address, account_id) do
    %Address{}
    |> change()
    |> put_change(:address, address)
    |> put_change(:account_id, account_id)
    |> put_default_value(:type, fn changeset ->
      case fetch_field(changeset, :address) do
        {_data_or_changes, inet} when tuple_size(inet.address) == 4 -> :ipv4
        {_data_or_changes, inet} when tuple_size(inet.address) == 8 -> :ipv6
        _other -> nil
      end
    end)
    |> validate_required([:type, :address])
    |> validate_inclusion(:type, Ecto.Enum.values(Address, :type))
  end
end
