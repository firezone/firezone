defmodule Domain.Actors.Group.Changeset do
  use Domain, :changeset
  alias Domain.Auth
  alias Domain.Actors

  @fields ~w[name type last_synced_at]a

  def upsert_conflict_target do
    {:unsafe_fragment,
     "(account_id, provider_id, provider_identifier) " <>
       "WHERE provider_id IS NOT NULL AND provider_identifier IS NOT NULL"}
  end

  def upsert_on_conflict, do: {:replace, ~w[name updated_at]a}

  def create(%Domain.Account{} = account, attrs, %Auth.Subject{} = _subject) do
    %Actors.Group{memberships: []}
    |> cast(attrs, @fields)
    |> validate_required(~w[name type]a)
    |> validate_inclusion(:type, ~w[static]a)
    |> changeset()
    |> put_change(:account_id, account.id)
    |> cast_membership_assocs(account.id)
  end

  def create(%Domain.Account{} = account, attrs) do
    %Actors.Group{memberships: []}
    |> cast(attrs, ~w[name last_synced_at]a)
    |> validate_required(~w[name]a)
    |> put_change(:type, :managed)
    |> changeset()
    |> put_change(:account_id, account.id)
    |> cast_membership_assocs(account.id)
  end

  def update(%Actors.Group{} = group, attrs) do
    group
    |> cast(attrs, ~w[name last_synced_at]a)
    |> validate_required(~w[name]a)
    |> validate_inclusion(:type, ~w[static]a)
    |> changeset()
    |> cast_membership_assocs(group.account_id)
  end

  defp changeset(changeset) do
    changeset
    |> trim_change(@fields)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name, name: :actor_groups_account_id_name_index)
  end

  defp cast_membership_assocs(changeset, account_id) do
    case fetch_field(changeset, :type) do
      {_data_or_changes, :static} ->
        cast_assoc(changeset, :memberships,
          with: &membership_changeset_for_group(account_id, &1, &2)
        )

      _other ->
        changeset
    end
  end

  defp membership_changeset_for_group(account_id, membership, attrs) do
    membership
    |> cast(attrs, ~w[actor_id last_synced_at]a)
    |> validate_required(~w[actor_id]a)
    |> Domain.Membership.changeset()
    |> put_change(:account_id, account_id)
  end
end
