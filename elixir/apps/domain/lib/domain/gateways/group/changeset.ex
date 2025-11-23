defmodule Domain.Gateways.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Gateways

  @fields ~w[name]a

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = _subject) do
    %Gateways.Group{account: account}
    |> changeset(attrs)
    |> put_default_value(:managed_by, :account)
    |> put_change(:account_id, account.id)
  end

  def create(%Accounts.Account{} = account, attrs) do
    %Gateways.Group{account: account}
    |> changeset(attrs)
    |> cast(attrs, ~w[managed_by]a)
    |> put_default_value(:managed_by, :account)
    |> put_change(:account_id, account.id)
  end

  def update(%Gateways.Group{} = group, attrs, %Auth.Subject{}) do
    changeset(group, attrs)
  end

  def update(%Gateways.Group{} = group, attrs) do
    changeset(group, attrs)
  end

  defp changeset(%Gateways.Group{} = group, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(@fields)
    |> put_default_value(:name, &Domain.NameGenerator.generate/0)
    |> validate_required(@fields)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :gateway_groups_account_id_name_managed_by_index)
  end
end
