defmodule Domain.Resources.Resource.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Resources.{Resource, Connection}

  @fields ~w[address name]a
  @update_fields ~w[name]a
  @required_fields ~w[address]a

  def create_changeset(%Accounts.Account{} = account, attrs) do
    %Resource{}
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> changeset()
    |> put_change(:account_id, account.id)
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2),
      required: true
    )
  end

  def finalize_create_changeset(%Resource{} = resource, ipv4, ipv6) do
    resource
    |> change()
    |> put_change(:ipv4, ipv4)
    |> put_change(:ipv6, ipv6)
    |> unique_constraint(:ipv4, name: :resources_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :resources_account_id_ipv6_index)
  end

  def update_changeset(%Resource{} = resource, attrs) do
    resource
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> changeset()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(resource.account_id, &1, &2),
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
