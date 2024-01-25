defmodule Domain.Actors.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Actors

  def upsert_conflict_target do
    {:unsafe_fragment,
     "(account_id, provider_id, provider_identifier) " <>
       "WHERE deleted_at IS NULL AND provider_id IS NOT NULL AND provider_identifier IS NOT NULL"}
  end

  def upsert_on_conflict, do: {:replace, ~w[name updated_at]a}

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Actors.Group{}
    |> cast(attrs, ~w[name]a)
    |> validate_required(~w[name]a)
    |> changeset()
    |> put_change(:account_id, account.id)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.for_group(account.id, &1, &2)
    )
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def create(%Auth.Provider{} = provider, attrs) do
    %Actors.Group{}
    |> cast(attrs, ~w[name provider_identifier]a)
    |> validate_required(~w[name provider_identifier]a)
    |> changeset()
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, provider.account_id)
    |> put_change(:created_by, :provider)
  end

  def update(%Actors.Group{} = group, attrs) do
    group
    |> cast(attrs, ~w[name]a)
    |> validate_required(~w[name]a)
    |> changeset()
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.for_group(group.account_id, &1, &2)
    )
  end

  defp changeset(changeset) do
    changeset
    |> trim_change(:name)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :actor_groups_account_id_name_index)
  end
end
