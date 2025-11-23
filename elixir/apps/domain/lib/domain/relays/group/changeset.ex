defmodule Domain.Relays.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Relays

  @fields ~w[name]a

  def create(attrs) do
    %Relays.Group{}
    |> changeset(attrs)
  end

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = _subject) do
    %Relays.Group{account: account}
    |> changeset(attrs)
    |> put_change(:account_id, account.id)
  end

  def update(%Relays.Group{} = group, attrs, %Auth.Subject{}) do
    changeset(group, attrs)
  end

  def update(%Relays.Group{} = group, attrs) do
    changeset(group, attrs)
  end

  defp changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(@fields)
    |> put_default_value(:name, &Domain.NameGenerator.generate/0)
    |> validate_required(@fields)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :relay_groups_name_index)
    |> unique_constraint(:name, name: :relay_groups_account_id_name_index)
  end
end
