defmodule Domain.Resources.Resource.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts, Network}
  alias Domain.Resources.{Resource, Connection}

  @fields ~w[address name type]a
  @update_fields ~w[name]a
  @required_fields ~w[address type]a

  def create_changeset(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Resource{}
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> changeset()
    |> put_change(:account_id, account.id)
    |> validate_address()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2, subject),
      required: true
    )
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def finalize_create_changeset(%Resource{} = resource, ipv4, ipv6) do
    resource
    |> change()
    |> put_change(:ipv4, ipv4)
    |> put_change(:ipv6, ipv6)
    |> unique_constraint(:ipv4, name: :resources_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :resources_account_id_ipv6_index)
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

        _other ->
          changeset
      end
    end
  end

  defp validate_dns_address(changeset) do
    validate_length(changeset, :address, min: 1, max: 253)
  end

  defp validate_cidr_address(changeset) do
    changeset = validate_and_normalize_cidr(changeset, :address)

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

  def update_changeset(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
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
    |> put_default_value(:name, from: :address)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:address, name: :resources_account_id_address_index)
    |> unique_constraint(:name, name: :resources_account_id_name_index)
    |> cast_embed(:filters, with: &cast_filter/2)
    |> unique_constraint(:ipv4, name: :resources_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :resources_account_id_ipv6_index)
    |> exclusion_constraint(:address,
      name: :resources_account_id_cidr_address_index,
      message: "can not overlap with other resource ranges"
    )
  end

  def delete_changeset(%Resource{} = resource) do
    resource
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  defp cast_filter(%Resource.Filter{} = filter, attrs) do
    filter
    |> cast(attrs, [:protocol, :ports])
  end
end
