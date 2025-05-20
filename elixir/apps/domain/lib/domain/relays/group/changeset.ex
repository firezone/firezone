defmodule Domain.Relays.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Relays

  @fields ~w[name]a

  def create(attrs) do
    %Relays.Group{}
    |> changeset(attrs)
    |> put_subject_trail(:created_by, :system)
  end

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Relays.Group{account: account}
    |> changeset(attrs)
    |> put_change(:account_id, account.id)
    |> put_subject_trail(:created_by, subject)
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
    |> trim_change(:name)
    |> put_default_value(:name, &Domain.NameGenerator.generate/0)
    |> validate_required(@fields)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :relay_groups_name_index)
    |> unique_constraint(:name, name: :relay_groups_account_id_name_index)
  end

  def delete(%Relays.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
