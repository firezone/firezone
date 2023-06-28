defmodule Domain.Actors.Group.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Actors

  @fields ~w[name]a

  def create_changeset(%Accounts.Account{} = account, attrs) do
    %Actors.Group{account_id: account.id}
    |> changeset(attrs)
  end

  def update_changeset(%Actors.Group{} = group, attrs) do
    changeset(group, attrs)
  end

  defp changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> trim_change(:name)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :actor_groups_account_id_name_index)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.group_changeset(group.account_id, &1, &2)
    )
  end

  def delete_changeset(%Actors.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
