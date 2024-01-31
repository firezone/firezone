defmodule Domain.Resources.Resource.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts, Network}
  alias Domain.Resources.{Resource, Connection}

  @fields ~w[address client_address name type]a
  @update_fields ~w[name client_address]a
  @required_fields ~w[address client_address type]a

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Resource{connections: []}
    |> cast(attrs, @fields)
    |> changeset()
    |> validate_required(@required_fields)
    |> put_change(:account_id, account.id)
    |> validate_address()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2, subject),
      required: true
    )
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def create(%Accounts.Account{} = account, attrs) do
    %Resource{connections: []}
    |> cast(attrs, @fields)
    |> changeset()
    |> validate_required(@required_fields)
    |> validate_address()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2)
    )
  end

  defp validate_address(changeset) do
    if has_errors?(changeset, :type) do
      changeset
    else
      case fetch_field(changeset, :type) do
        {_data_or_changes, :dns} ->
          validate_dns_address(changeset)

        {_data_or_changes, :cidr} ->
          validate_cidr_address(changeset)

        {_data_or_changes, :ip} ->
          validate_ip_address(changeset)

        _other ->
          changeset
      end
    end
  end

  defp validate_dns_address(changeset) do
    changeset
    |> validate_length(:address, min: 1, max: 253)
    |> validate_does_not_end_with(:address, "localhost",
      message: "localhost can not be used, please add a DNS alias to /etc/hosts instead"
    )
    |> validate_format(:address, ~r/^([*?]\.)?[\p{L}0-9-]{1,63}(\.[\p{L}0-9-]{1,63})*$/iu)
  end

  defp validate_cidr_address(changeset) do
    changeset
    |> validate_and_normalize_cidr(:address)
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 32},
      message: "can not contain all IPv4 addresses"
    )
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {127, 0, 0, 0}, netmask: 8},
      message: "can not contain loopback addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 0},
        netmask: 128
      },
      message: "can not contain all IPv6 addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 1},
        netmask: 128
      },
      message: "can not contain loopback addresses"
    )
    |> validate_address_is_not_in_private_range()
  end

  defp validate_ip_address(changeset) do
    changeset
    |> validate_and_normalize_ip(:address)
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 32},
      message: "can not contain all IPv4 addresses"
    )
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {127, 0, 0, 0}, netmask: 8},
      message: "can not contain loopback addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 0},
        netmask: 128
      },
      message: "can not contain all IPv6 addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 1},
        netmask: 128
      },
      message: "can not contain loopback addresses"
    )
    |> validate_address_is_not_in_private_range()
  end

  defp validate_address_is_not_in_private_range(changeset) do
    cond do
      has_errors?(changeset, :address) ->
        changeset

      get_field(changeset, :address) == "0.0.0.0/0" ->
        changeset

      get_field(changeset, :address) == "::/0" ->
        changeset

      true ->
        Network.cidrs()
        |> Enum.reduce(changeset, fn {_type, cidr}, changeset ->
          validate_not_in_cidr(changeset, :address, cidr)
        end)
    end
  end

  def update(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
    resource
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> changeset()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(resource.account_id, &1, &2, subject),
      required: true
    )
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:client_address, min: 1, max: 253)
    |> validate_contains(:client_address, field: :address)
    |> cast_embed(:filters, with: &cast_filter/2)
    |> unique_constraint(:ipv4, name: :resources_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :resources_account_id_ipv6_index)
  end

  def delete(%Resource{} = resource) do
    resource
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  defp cast_filter(%Resource.Filter{} = filter, attrs) do
    filter
    |> cast(attrs, [:protocol, :ports])
    |> validate_required([:protocol])
  end
end
