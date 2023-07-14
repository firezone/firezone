defmodule Domain.Actors.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Actors

  @fields ~w[name]a

  def upsert_conflict_target do
    {:unsafe_fragment,
     "(account_id, provider_id, provider_identifier) " <>
       "WHERE deleted_at IS NULL AND provider_id IS NOT NULL AND provider_identifier IS NOT NULL"}
  end

  # We do not update the `name` field because we allow to manually override it in the UI
  # for usability reasons when the provider uses group names that can make people confused
  def upsert_on_conflict, do: {:replace, (@fields -- ~w[name]a) ++ ~w[updated_at]a}

  def create_changeset(%Accounts.Account{} = account, attrs) do
    %Actors.Group{account_id: account.id}
    |> changeset(attrs)
    |> validate_length(:name, min: 1, max: 64)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.group_changeset(account.id, &1, &2)
    )
  end

  def create_changeset(%Auth.Provider{} = provider, provider_identifier, attrs) do
    %Actors.Group{}
    |> changeset(attrs)
    |> put_change(:provider_id, provider.id)
    |> put_change(:provider_identifier, provider_identifier)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.group_changeset(provider.account_id, &1, &2)
    )
  end

  def update_changeset(%Actors.Group{} = group, attrs) do
    changeset(group, attrs)
    |> validate_length(:name, min: 1, max: 64)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.group_changeset(group.account_id, &1, &2)
    )
  end

  defp changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> trim_change(:name)
    |> unique_constraint(:name, name: :actor_groups_account_id_name_index)
  end

  def delete_changeset(%Actors.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
